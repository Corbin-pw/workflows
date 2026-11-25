#!/usr/bin/env bash
# lib/stack-tests.sh -- runs as the cluster user on the controller (pushed and
# started by 07-test-stack.sh). Exercises a spack-builder stack the way users
# will: modules, compile, multi-node launch with each MPI, OSU, a real GROMACS
# simulation per MPI, and what a batch job's environment looks like.
# Usage: stack-tests.sh [RUN_DIR]   (default: newest successful full build)
# No `set -u`: Lmod's shell functions reference unset variables.
set -o pipefail
type module >/dev/null 2>&1 || . /usr/share/lmod/lmod/init/bash

RUN="${1:-}"
if [ -z "$RUN" ]; then
  for d in $(ls -d ~/pw/jobs/*/*/ 2>/dev/null | sort); do
    # A dry run (concretize_only) also exits 0 and writes modulepath.env, but
    # installs and generates nothing: never pick one by default.
    [ "$(cat "$d/build/BUILD_STATUS" 2>/dev/null)" = 0 ] && [ -s "$d/modulepath.env" ] && ! grep -qs 'service_concretize_only="true"' "$d/inputs.sh" && RUN="${d%/}"
  done
fi
[ -n "$RUN" ] && [ -s "$RUN/modulepath.env" ] || { echo "no successful full build found (need build/BUILD_STATUS=0 and modulepath.env)"; exit 2; }
ENV_DIR="$RUN/spack-env"
export MODULEPATH="$(cat "$RUN/modulepath.env")${MODULEPATH:+:$MODULEPATH}"
# The Spack root this run built into (inputs.sh), not an assumed ~/spack.
SPROOT="$(set +u; . "$RUN/inputs.sh" >/dev/null 2>&1; echo "${service_install_prefix:-$HOME/spack}")"
LOGIN_HOOK="$(set +u; . "$RUN/inputs.sh" >/dev/null 2>&1; echo "${service_login_hook:-false}")"
. "$SPROOT/share/spack/setup-env.sh"
W="/scratch/stack-tests-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$W"; cd "$W"
N1="${TB_NODES_PER_JOB:-2}"; PPN=2

declare -a R
say()  { printf '\n=== %s ===\n' "$*"; }
check() { local n="$1"; shift; local out; if out="$("$@" 2>&1)"; then R+=("PASS  $n"); echo "  [ OK ] $n"; else R+=("FAIL  $n"); echo "  [FAIL] $n"; fi; printf '%s\n' "$out" | tail -8 | sed 's/^/         /'; }
# Lmod's terse listing prints a "name/" directory line before the versions.
# A GPU build carries a -cuda- twin of openmpi, gromacs, ...; the CPU tests
# must not pick it up, so -cuda- names are skipped unless a 3rd arg says otherwise.
# Patterns go after -e: the default exclude starts with '-', and a bare
# `grep -vE -cuda-` reads it as options and matches nothing.
modname() { module -t avail "$1" 2>&1 | grep -E -e "^$1/." | grep -E -e "${2:-.}" | grep -vE -e "${3:--cuda-}" | head -1; }
# Unloading a module must leave the shell usable. Modules generated from vendor
# environment scripts (intel-oneapi-*) can SET PATH rather than prepend to it,
# and unloading them then removes PATH altogether -- every later command fails.
# Report that as its own failure and restore the base environment.
BASE_PATH="$PATH"; BASE_LD="${LD_LIBRARY_PATH:-}"
LOADED=""
clean_env() {  # unload everything; blame $LOADED if PATH does not survive
  module purge >/dev/null 2>&1
  if [ "$PATH" != "$BASE_PATH" ] && ! PATH="$PATH" command -v grep >/dev/null 2>&1; then
    R+=("FAIL  ${LOADED:-?}: unloading it wipes PATH (modulefile sets PATH instead of prepending)")
    echo "  [FAIL] ${LOADED:-?}: unloading it wipes PATH"
  fi
  export PATH="$BASE_PATH" LD_LIBRARY_PATH="$BASE_LD"; LOADED=""
}

say "Stack under test"
echo "  run dir    : $RUN"
echo "  MODULEPATH : $(cat "$RUN/modulepath.env")"
echo "  spack root : $SPROOT"
echo "  work dir   : $W (shared /scratch)"
module -t avail 2>&1 | grep -vE '^/|:$' | sed 's/^/  module: /'

cat > hello.c <<'C'
#include <mpi.h>
#include <stdio.h>
int main(int c, char **v) {
  int r, n, l; char h[MPI_MAX_PROCESSOR_NAME], lib[MPI_MAX_LIBRARY_VERSION_STRING];
  MPI_Init(&c, &v); MPI_Comm_rank(MPI_COMM_WORLD, &r); MPI_Comm_size(MPI_COMM_WORLD, &n);
  MPI_Get_processor_name(h, &l); MPI_Get_library_version(lib, &l);
  if (r == 0) { for (char *e = lib; *e; e++) if (*e == '\n') *e = ' '; printf("library: %.70s\n", lib); }
  printf("rank %d of %d on %s\n", r, n, h);
  MPI_Finalize(); return 0;
}
C
# Two ranks per node on N1 nodes, ranks spread over both nodes.
# A launch that did not wire the ranks together still prints N lines -- each
# rank a singleton saying "rank 0 of 1" -- so the world size is checked too.
ranks_ok() { local f="$1" want=$(( N1 * PPN ));
  [ "$(grep -c "^rank [0-9]* of ${want} on " "$f")" = "$want" ] \
  && [ "$(grep '^rank ' "$f" | awk '{print $2}' | sort -un | wc -l)" = "$want" ] \
  && [ "$(grep '^rank ' "$f" | awk '{print $NF}' | sort -u | wc -l)" = "$N1" ] \
  || { echo "expected ranks 0..$((want-1)) 'of ${want}' on ${N1} nodes"; return 1; }; }

# Launchers, one per MPI, as users are told to use them on this cluster:
#   openmpi          srun (MpiDefault=pmix), plus mpirun inside an allocation
#   mpich            srun --mpi=pmix or --mpi=pmi2, whichever PMI it was built with
#   intel-oneapi-mpi mpirun inside an allocation (hydra bootstraps through Slurm)
launch() {  # launch MPI NODES NTASKS_PER_NODE cmd...
  local m="$1" n="$2" p="$3"; shift 3
  case "$m" in
    openmpi)          srun -N"$n" --ntasks-per-node="$p" -c "${CPT:-1}" -t 5 "$@" ;;
    openmpi-mpirun)   salloc -N"$n" --ntasks-per-node="$p" -t 5 mpirun -n $((n*p)) "$@" ;;
    mpich)            srun -N"$n" --ntasks-per-node="$p" -c "${CPT:-1}" --mpi="$MPICH_PMI" -t 5 "$@" ;;
    intel-oneapi-mpi) FI_PROVIDER=tcp I_MPI_FABRICS=shm:ofi salloc -N"$n" --ntasks-per-node="$p" -t 5 mpirun -n $((n*p)) "$@" ;;
  esac
}

# build.sh builds MPICH with pmi=pmix where Slurm offers PMIx, pmi=pmi2 otherwise.
MPICH_PMI=pmi2; grep -q 'pmi=pmix' "$ENV_DIR/spack.yaml" 2>/dev/null && MPICH_PMI=pmix
export MPICH_PMI
echo "  MPICH PMI  : $MPICH_PMI (from $ENV_DIR/spack.yaml)"
GCC_MOD="$(modname gcc)"
say "Compiler module"
check "gcc module present (${GCC_MOD:-none})" test -n "$GCC_MOD"
check "gcc module gives gcc 14" bash -c "module load $GCC_MOD && gcc --version | head -1 | grep -q ' 14\.'"

# Every CPU module of each MPI, not just the first: with an extra version
# installed (mpich 3.4.3 beside 4.2.2) `module -t avail mpich` lists both, and
# taking the first would have silently tested 3.4.3 in place of the default.
for M in openmpi mpich intel-oneapi-mpi; do
  say "$M"
  MODS="$(module -t avail "$M" 2>&1 | grep -E -e "^$M/." | grep -vE -e '-cuda-|-cuda$' | sort -u)"
  check "$M: module present (${MODS:-none})" test -n "$MODS"
  for MOD in $MODS; do
    V="${MOD#*/}"; V="${V%%-*}"; T="${M}-${V}"
    clean_env; module load "$GCC_MOD" "$MOD"; LOADED="$MOD"
    check "$MOD: mpicc compiles with gcc 14" bash -c "mpicc --version 2>&1 | head -1 | grep -q ' 14\.' && mpicc -o hello_$T hello.c"
    launchers="$M"; [ "$M" = openmpi ] && launchers="openmpi openmpi-mpirun"
    for L in $launchers; do
      check "$MOD: hello, ${N1} nodes x ${PPN} ranks via ${L}" bash -c "$(declare -f launch ranks_ok); N1=$N1 PPN=$PPN; launch $L $N1 $PPN ./hello_$T > hello_${L}_$V.out 2>&1; cat hello_${L}_$V.out; grep -qF '${V%.*}' hello_${L}_$V.out || { echo 'library version is not ${V%.*}'; exit 1; }; ranks_ok hello_${L}_$V.out"
    done
    OSU="$(spack -e "$ENV_DIR" find --format '{prefix}' "osu-micro-benchmarks ~cuda ^$M@$V" 2>/dev/null | head -1)"
    if [ -n "$OSU" ]; then
      B="$OSU/libexec/osu-micro-benchmarks/mpi/pt2pt"
      check "$MOD: osu_latency between nodes" bash -c "$(declare -f launch); launch $M 2 1 $B/osu_latency -m 8:1048576 > osu_lat_$T.out 2>&1; cat osu_lat_$T.out; grep -qE '^1048576' osu_lat_$T.out"
      check "$MOD: osu_bw between nodes"      bash -c "$(declare -f launch); launch $M 2 1 $B/osu_bw -m 1048576:4194304 > osu_bw_$T.out 2>&1; cat osu_bw_$T.out; grep -qE '^4194304' osu_bw_$T.out"
    else R+=("FAIL  $MOD: no osu-micro-benchmarks built against it"); fi
  done
  # `module load <name>` must still give the newest VERSION (mpich 4.2.2, not
  # an extra 3.4.3). Compared by version, not by full module name: one version
  # can have several modules (a CPU-only run names them without a hash, a GPU
  # run with one), and which of those Lmod picks says nothing about versions.
  NV="$(for x in $MODS; do v="${x#*/}"; echo "${v%%-*}"; done | sort -uV | tail -1)"
  if [ "$(for x in $MODS; do v="${x#*/}"; echo "${v%%-*}"; done | sort -u | wc -l)" -gt 1 ]; then
    clean_env
    check "$M: 'module load $M' gives the newest version ($NV)" bash -c "module load $M || exit 1; got=\$(module -t list 2>&1 | grep -E '^$M/'); echo \"loaded: \$got\"; v=\${got#*/}; [ \"\${v%%-*}\" = '$NV' ]"
  fi
done

say "GROMACS: a ~17k-atom water box, minimised, then 2000 MD steps per MPI"
GMX_OMPI="$(modname gromacs openmpi)"
if [ -n "$GMX_OMPI" ]; then
  clean_env; module load "$GMX_OMPI"; LOADED="$GMX_OMPI"
  printf '#include "oplsaa.ff/forcefield.itp"\n#include "oplsaa.ff/spc.itp"\n\n[ system ]\nwater\n\n[ molecules ]\n' > topol.top
  # Energy minimisation first: solvate tiles the 1.86 nm spc216 box, and even
  # an exact multiple (3 x 1.86 = 5.58 nm) leaves contacts at the seams that
  # blow up MD at step ~4 ("water molecules can not be settled") without it.
  cat > em.mdp <<'MDP'
integrator = steep
nsteps = 500
emtol = 1000
cutoff-scheme = Verlet
coulombtype = PME
rcoulomb = 1.0
rvdw = 1.0
MDP
  cat > md.mdp <<'MDP'
integrator = md
dt = 0.002
nsteps = 2000
cutoff-scheme = Verlet
nstlist = 20
coulombtype = PME
rcoulomb = 1.0
rvdw = 1.0
tcoupl = v-rescale
tc-grps = System
tau_t = 0.1
ref_t = 300
gen_vel = yes
gen_temp = 300
nstlog = 500
nstenergy = 500
MDP
  check "gromacs: build the input (solvate, minimise, grompp)" bash -c "set -e
    srun -n1 -t 5 gmx_mpi solvate -cs spc216.gro -box 5.58 5.58 5.58 -o water.gro -p topol.top
    srun -n1 -t 5 gmx_mpi grompp -f em.mdp -c water.gro -p topol.top -o em.tpr -maxwarn 1
    srun -n1 -c 4 -t 10 gmx_mpi mdrun -s em.tpr -deffnm em -ntomp 4
    srun -n1 -t 5 gmx_mpi grompp -f md.mdp -c em.gro -p topol.top -o md.tpr -maxwarn 1
    test -s md.tpr"
fi
for M in openmpi mpich intel-oneapi-mpi; do
  GMX="$(modname gromacs "$M")"
  [ -n "$GMX" ] || { R+=("FAIL  gromacs/$M: no module"); continue; }
  clean_env; module load "$GMX"; LOADED="$GMX"
  check "gromacs/$M: mdrun ${N1} nodes x ${PPN} ranks x 2 threads" bash -c "$(declare -f launch); export CPT=2; [ -s md.tpr ] && launch $M $N1 $PPN env OMP_NUM_THREADS=2 gmx_mpi mdrun -s md.tpr -deffnm md_$M -ntomp 2 > mdrun_$M.out 2>&1; tail -3 mdrun_$M.out; grep -E 'Performance:' md_$M.log"
done

clean_env
if [ "$LOGIN_HOOK" = "true" ]; then
  say "Login hook: a NEW login shell on every node finds the stack"
  TREE="$(cut -d: -f1 "$RUN/modulepath.env")"
  check "login node $(hostname -s): MODULEPATH has $TREE and openmpi loads" \
    env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin bash -lc \
      "echo \$MODULEPATH; case :\$MODULEPATH: in *:$TREE:*) ;; *) exit 1;; esac; module -t avail openmpi 2>&1 | grep -q '^openmpi/.' && module load openmpi && command -v mpicc"
  for node in $(sinfo -h -N -o '%N %T' | awk '$2 !~ /down|drain|fail/ {print $1}' | sort -u); do
    # --export=NONE: a fresh login environment on the node, not this shell's.
    # That includes no PATH, so the shell must be named by its full path
    # (plain `bash` fails with "execve(): bash: No such file or directory").
    check "$node: MODULEPATH has $TREE at login and openmpi loads" \
      srun -w "$node" -N1 -n1 -t 2 --export=NONE /bin/bash -lc \
        "echo \$MODULEPATH; case :\$MODULEPATH: in *:$TREE:*) ;; *) exit 1;; esac; module load openmpi && command -v mpicc"
  done
fi

# ============================================================================
# GPU path (only when the environment was built with it)
# ============================================================================
if grep -qE '^\s*- cuda\s*$' "$ENV_DIR/spack.yaml"; then
  say "GPU stack"
  clean_env
  # cuda_arch: from the environment, else the detected profile, else the GPU.
  ARCH="$(grep -oE 'cuda_arch[=:] *[0-9]+' "$ENV_DIR/spack.yaml" | head -1 | grep -oE '[0-9]+$')"
  [ -n "$ARCH" ] || ARCH="$(set +u; . "$RUN/fabric.env" 2>/dev/null; echo "${GPU_ARCH:-}")"
  GPU_NODES="$(sinfo -h -N -o '%N %G %T' | awk '$2 ~ /gpu/ && $3 !~ /down|drain/ {print $1}' | sort -u | tr '\n' ' ')"
  pfx() { spack -e "$ENV_DIR" find --format '{prefix}' "$1" 2>/dev/null | head -1; }
  [ -n "$ARCH" ] || ARCH="$(srun -w "${GPU_NODES%% *}" -N1 -n1 --gres=gpu:1 -t 1 nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '. ')"
  echo "  cuda_arch=${ARCH:-?}  GPU nodes: ${GPU_NODES:-none}"
  CUDA_MOD="$(modname cuda '' '^$')"
  check "cuda module present (${CUDA_MOD:-none})" test -n "$CUDA_MOD"
  module load "$GCC_MOD" "$CUDA_MOD"; LOADED="$CUDA_MOD"
  check "nvcc is CUDA 12.8+ and uses gcc 14" bash -c "nvcc --version | tail -2; v=\$(nvcc --version | grep -oE 'release [0-9.]+' | cut -d' ' -f2); [ \"\$(printf '%s\n12.8\n' \$v | sort -V | head -1)\" = 12.8 ] && gcc --version | head -1 | grep -q ' 14\.'"

  cat > saxpy.cu <<'CU'
#include <cstdio>
#include <cmath>
__global__ void saxpy(int n, float a, const float *x, float *y) { int i = blockIdx.x * blockDim.x + threadIdx.x; if (i < n) y[i] = a * x[i] + y[i]; }
int main() {
  const int n = 1 << 20; float *x, *y;
  cudaMallocManaged(&x, n * sizeof(float)); cudaMallocManaged(&y, n * sizeof(float));
  for (int i = 0; i < n; i++) { x[i] = 1.0f; y[i] = 2.0f; }
  saxpy<<<(n + 255) / 256, 256>>>(n, 2.0f, x, y);
  cudaError_t e = cudaDeviceSynchronize();
  if (e != cudaSuccess) { printf("CUDA error: %s\n", cudaGetErrorString(e)); return 1; }
  float err = 0; for (int i = 0; i < n; i++) err = fmaxf(err, fabsf(y[i] - 4.0f));
  cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
  printf("saxpy on %s (sm_%d%d): max error %g\n", p.name, p.major, p.minor, err);
  return err == 0.0f ? 0 : 1;
}
CU
  check "nvcc builds a kernel for sm_${ARCH}" nvcc -arch=sm_${ARCH} -o saxpy saxpy.cu
  for node in $GPU_NODES; do
    check "$node: kernel runs on the GPU (--gres=gpu:1)" srun -w "$node" -N1 -n1 --gres=gpu:1 -t 2 ./saxpy
  done
  FIRST_GPU="${GPU_NODES%% *}"

  CUDNN="$(pfx cudnn)"
  if [ -n "$CUDNN" ]; then
    cat > cudnn_test.cu <<'CU'
#include <cstdio>
#include <cudnn.h>
int main() {
  printf("cuDNN %zu\n", (size_t)cudnnGetVersion());
  cudnnHandle_t h; cudnnStatus_t s = cudnnCreate(&h);
  if (s != CUDNN_STATUS_SUCCESS) { printf("cudnnCreate: %s\n", cudnnGetErrorString(s)); return 1; }
  cudnnDestroy(h); printf("cudnnCreate ok\n"); return 0;
}
CU
    check "cudnn: build + create a handle on $FIRST_GPU" bash -c "nvcc -I$CUDNN/include -L$CUDNN/lib -Xlinker -rpath=$CUDNN/lib -o cudnn_test cudnn_test.cu -lcudnn && srun -w $FIRST_GPU -N1 -n1 --gres=gpu:1 -t 2 ./cudnn_test"
  fi
  NCCL="$(pfx 'nccl +cuda')"
  if [ -n "$NCCL" ]; then
    cat > nccl_test.cu <<'CU'
#include <cstdio>
#include <nccl.h>
int main() {
  int v; ncclGetVersion(&v); printf("NCCL %d\n", v);
  ncclComm_t c; int dev = 0; ncclResult_t r = ncclCommInitAll(&c, 1, &dev);
  if (r != ncclSuccess) { printf("ncclCommInitAll: %s\n", ncclGetErrorString(r)); return 1; }
  float *b; cudaMalloc(&b, 1024 * sizeof(float)); cudaMemset(b, 0, 1024 * sizeof(float));
  r = ncclAllReduce(b, b, 1024, ncclFloat, ncclSum, c, 0); cudaStreamSynchronize(0);
  printf("ncclAllReduce: %s\n", ncclGetErrorString(r)); ncclCommDestroy(c);
  return r == ncclSuccess ? 0 : 1;
}
CU
    check "nccl: build + allreduce on $FIRST_GPU" bash -c "nvcc -I$NCCL/include -L$NCCL/lib -Xlinker -rpath=$NCCL/lib -o nccl_test nccl_test.cu -lnccl && srun -w $FIRST_GPU -N1 -n1 --gres=gpu:1 -t 2 ./nccl_test"
  fi
  NVSHMEM="$(pfx nvshmem)"
  if [ -n "$NVSHMEM" ]; then
    check "nvshmem: nvshmem-info runs on $FIRST_GPU" bash -c "ls $NVSHMEM/bin/ | head; srun -w $FIRST_GPU -N1 -n1 --gres=gpu:1 -t 2 $NVSHMEM/bin/nvshmem-info -a | head -15"
  fi
  CUFFTMP="$(pfx cufftmp)"
  if [ -n "$CUFFTMP" ]; then
    check "cufftmp: libcufftMp resolves (with nvshmem's lib dir)" bash -c "L=\$(find $CUFFTMP -name 'libcufftMp.so*' | head -1); echo \$L; [ -n \"\$L\" ] && ! LD_LIBRARY_PATH=${NVSHMEM:+$NVSHMEM/lib} ldd \$L | grep 'not found'"
  fi

  OSU_GPU="$(pfx 'osu-micro-benchmarks +cuda')"
  if [ -n "$OSU_GPU" ] && [ "$(echo $GPU_NODES | wc -w)" -ge 2 ]; then
    B="$OSU_GPU/libexec/osu-micro-benchmarks/mpi/pt2pt"
    check "CUDA-aware OpenMPI: osu_latency GPU->GPU between nodes" bash -c "srun -N2 --ntasks-per-node=1 --gres=gpu:1 -t 5 $B/osu_latency -d cuda -m 8:1048576 D D > osu_lat_gpu.out 2>&1; cat osu_lat_gpu.out; grep -qE '^1048576' osu_lat_gpu.out"
    check "CUDA-aware OpenMPI: osu_bw GPU->GPU between nodes"      bash -c "srun -N2 --ntasks-per-node=1 --gres=gpu:1 -t 5 $B/osu_bw -d cuda -m 1048576:4194304 D D > osu_bw_gpu.out 2>&1; cat osu_bw_gpu.out; grep -qE '^4194304' osu_bw_gpu.out"
  fi

  GMX_GPU="$(modname gromacs 'cuda' '^$')"
  if [ -n "$GMX_GPU" ] && [ -s md.tpr ]; then
    clean_env; module load "$GMX_GPU"; LOADED="$GMX_GPU"
    check "gromacs GPU ($GMX_GPU): mdrun with nonbonded, PME and update on the GPU" bash -c "srun -w $FIRST_GPU -N1 -n1 -c 4 --gres=gpu:1 -t 10 gmx_mpi mdrun -s md.tpr -deffnm md_gpu -ntomp 4 -nb gpu -pme gpu -update gpu > mdrun_gpu.out 2>&1; tail -3 mdrun_gpu.out; grep -iE 'GPU.*(selected|used)|on host.*GPU' md_gpu.log | head -3; grep -E 'Performance:' md_gpu.log"
  else
    R+=("FAIL  gromacs GPU: no -cuda gromacs module or no md.tpr")
  fi
  clean_env
fi

# ============================================================================
# Python environments and Conda/Mamba (only when the run built them)
# ============================================================================
# Environments are <name>-env modules written by build-python-envs.sh (not
# Spack's own py-* package modules).
# ============================================================================
# Additional software (service_extra_specs), tested when it is in the environment
# ============================================================================
in_env() { grep -qE "^\s*- ['\"]?$1( |['\"]|\$)" "$ENV_DIR/spack.yaml"; }
if in_env apptainer || in_env cmake || in_env git || in_env git-lfs; then
  say "Additional software"
  # A tool from the stack, not the OS copy: the OS has git and cmake too.
  from_stack() { case "$(command -v "$1")" in /usr/*|/bin/*|"") echo "$1 resolves to '$(command -v "$1")', not the stack"; return 1;; esac; command -v "$1"; }
  if in_env apptainer; then
    AMOD="$(modname apptainer)"
    check "apptainer: module present (${AMOD:-none})" test -n "$AMOD"
    if [ -n "$AMOD" ]; then
      clean_env; module load "$AMOD"; LOADED="$AMOD"
      check "apptainer: runs from the stack, no setuid starter" bash -c "$(declare -f from_stack); from_stack apptainer && apptainer --version && ! find \"\$(dirname \"\$(dirname \"\$(command -v apptainer)\")\")/libexec\" -name 'starter-suid' -perm -4000 2>/dev/null | grep -q ."
      # Pulled on the login node, run on a compute node as the user: the
      # unprivileged (user-namespace) path, which is the only one installed.
      check "apptainer: build a SIF from docker://busybox, run it on a compute node as $(id -un)" bash -c "set -e
        apptainer pull --force busybox.sif docker://busybox:1.36 >apptainer-build.log 2>&1 || { tail -5 apptainer-build.log; exit 1; }
        out=\$(srun -N1 -n1 -t 5 apptainer exec busybox.sif sh -c 'echo uid=\$(id -u) host=\$(hostname); head -1 /etc/os-release 2>/dev/null; busybox | head -1')
        echo \"\$out\"; echo \"\$out\" | grep -q \"uid=$(id -u) \" && echo \"\$out\" | grep -qi busybox"
    fi
  fi
  if in_env cmake; then
    CMOD="$(modname cmake)"
    check "cmake: module present (${CMOD:-none})" test -n "$CMOD"
    if [ -n "$CMOD" ]; then
      clean_env; module load "$GCC_MOD" "$CMOD"; LOADED="$CMOD"
      mkdir -p cmk && printf 'cmake_minimum_required(VERSION 3.23)\nproject(hi C)\nadd_executable(hi hi.c)\n' > cmk/CMakeLists.txt && printf '#include <stdio.h>\nint main(void){puts("cmake ok");return 0;}\n' > cmk/hi.c
      check "cmake: version >= 3.23 and a project builds with gcc 14" bash -c "$(declare -f from_stack); set -e; from_stack cmake; v=\$(cmake --version | head -1 | awk '{print \$3}'); echo \"cmake \$v\"; printf '3.23\n%s\n' \"\$v\" | sort -V -C
        cmake -S cmk -B cmk/build -DCMAKE_C_COMPILER=gcc >cmk.log 2>&1 || { tail -5 cmk.log; exit 1; }; grep -E 'C compiler identification' cmk.log
        cmake --build cmk/build >>cmk.log 2>&1 && ./cmk/build/hi"
    fi
  fi
  if in_env git || in_env git-lfs; then
    GMOD="$(modname git '' '-cuda-|^git-lfs/')"; LMOD_LFS="$(modname git-lfs)"
    check "git: module present (${GMOD:-none})" test -n "$GMOD"
    in_env git-lfs && check "git-lfs: module present (${LMOD_LFS:-none})" test -n "$LMOD_LFS"
    if [ -n "$GMOD" ]; then
      clean_env; module load $GMOD $LMOD_LFS; LOADED="$GMOD"
      check "git: from the stack; commit and log in a new repository" bash -c "$(declare -f from_stack); set -e; from_stack git; git --version
        rm -rf gitrepo; git init -q gitrepo; cd gitrepo; echo hi > a.txt; git add a.txt
        git -c user.name=tb -c user.email=tb@example.invalid commit -qm first; git log --oneline | grep -q first"
      if grep -qE "git ?\+tcltk|git.*tcltk" "$ENV_DIR/spack.yaml"; then
        # The GUIs need an X display to open, so check they are installed and
        # their Tk interpreter is the stack's; run them with ssh -X or a desktop.
        check "git GUI: git-gui and gitk installed, and gitk's Tk interpreter (wish) exists" bash -c "set -e; ls \"\$(git --exec-path)/git-gui\"; g=\$(command -v gitk); echo \$g; w=\$(grep -m1 -oE '/[^ \"]*/wish[0-9.]*' \$g); echo \"wish: \$w\"; test -x \"\$w\""
      fi
      if [ -n "$LMOD_LFS" ]; then
        check "git-lfs: tracks and stores a file as an LFS pointer" bash -c "set -e; git lfs version; cd gitrepo
          git lfs install --local >/dev/null; git lfs track '*.bin' >/dev/null; head -c 100000 /dev/urandom > blob.bin; git add .gitattributes blob.bin
          git -c user.name=tb -c user.email=tb@example.invalid commit -qm lfs; git lfs ls-files | grep -q blob.bin
          git show HEAD:blob.bin | grep -q '^version https://git-lfs'"
      fi
    fi
  fi
  clean_env
fi

PY_MODS="$(module -t avail 2>&1 | grep -E -e '^[A-Za-z0-9._]+-env/$' | tr -d / | sort -u | tr '\n' ' ')"
if [ -n "$PY_MODS" ]; then
  say "Python environments: $PY_MODS"
  FIRST_GPU="${FIRST_GPU:-$(sinfo -h -N -o '%N %G %T' | awk '$2 ~ /gpu/ && $3 !~ /down|drain/ {print $1; exit}')}"
  for pm in $PY_MODS; do
    clean_env
    # A modulefile with a Tcl error loads nothing and only says so on stderr;
    # report that as itself rather than as a missing python.
    if ! module load "$pm" 2>"lmod-$pm.err" || grep -qiE 'error' "lmod-$pm.err"; then
      R+=("FAIL  $pm: module does not load"); echo "  [FAIL] $pm: module does not load"; sed 's/^/         /' "lmod-$pm.err" | head -6
      continue
    fi
    LOADED="$pm"
    check "$pm: python is the Spack build and pip check is clean" bash -c "command -v python; python -c 'import sys; print(sys.version.split()[0], sys.prefix)'; python -m pip check"
  done
  if module -t avail ml-env 2>&1 | grep -q '^ml-env/.'; then
    clean_env; module load ml-env; LOADED=ml-env
    cat > ml_gpu.py <<'PYT'
import torch, jax, openmm, transformers
print("torch", torch.__version__, "cuda", torch.version.cuda, "available", torch.cuda.is_available())
assert torch.cuda.is_available(), "torch sees no GPU"
dev = torch.device("cuda"); print("  device:", torch.cuda.get_device_name(0), "arch list:", torch.cuda.get_arch_list())
a = torch.randn(1024, 1024, device=dev); print("  matmul ok:", float((a @ a).sum()) == float((a @ a).sum()))
gpus = [d for d in jax.devices() if d.platform == "gpu"]; print("jax", jax.__version__, "devices:", jax.devices())
assert gpus, "jax sees no GPU"
print("  jax sum on gpu:", float(jax.numpy.ones(1000).sum()))
names = [openmm.Platform.getPlatform(i).getName() for i in range(openmm.Platform.getNumPlatforms())]
print("openmm", openmm.__version__, "platforms:", names); assert "CUDA" in names, "OpenMM has no CUDA platform"
from transformers import EsmConfig, EsmModel
cfg = EsmConfig(vocab_size=33, hidden_size=64, num_hidden_layers=2, num_attention_heads=4, intermediate_size=128, pad_token_id=1, mask_token_id=32)
m = EsmModel(cfg).to(dev).eval()
with torch.no_grad(): out = m(torch.randint(4, 24, (2, 50), device=dev))
print("transformers", transformers.__version__, "ESM-2 architecture forward on GPU:", tuple(out.last_hidden_state.shape))
PYT
    check "ml-env on $FIRST_GPU: torch, jax and OpenMM see the GPU; ESM-2 model runs on it" srun -w "$FIRST_GPU" -N1 -n1 -c 4 --gres=gpu:1 -t 10 python ml_gpu.py
  fi
  if module -t avail esm3-env 2>&1 | grep -q '^esm3-env/.'; then
    clean_env; module load esm3-env; LOADED=esm3-env
    check "esm3-env: ESM-3 classes import (no weights downloaded)" python -c "import esm, torch; from esm.models.esm3 import ESM3; from esm.sdk.api import ESMProtein; print('esm', getattr(esm, '__version__', '?'), 'torch', torch.__version__)"
  fi
  clean_env
fi
if module -t avail miniforge3 2>&1 | grep -q '^miniforge3/.'; then
  say "Conda/Mamba (miniforge3)"
  clean_env; module load miniforge3; LOADED=miniforge3
  check "conda and mamba run" bash -c "conda --version && mamba --version | head -1"
  check "only conda-forge is configured" bash -c "conda config --show channels default_channels; ! conda config --show channels default_channels | grep -qiE 'repo.anaconda.com|/pkgs/main|/pkgs/r'"
  check "a solve uses conda-forge only (dry run, python=3.11 numpy)" bash -c "out=\$(conda create --dry-run --json -q -n tb-dryrun python=3.11 numpy 2>&1); printf '%s' \"\$out\" | grep -oE '\"channel\": *\"[^\"]*\"' | sort -u; printf '%s' \"\$out\" | grep -q '\"channel\": *\"conda-forge\"' && ! printf '%s' \"\$out\" | grep -qE '\"channel\": *\"(pkgs/main|main|anaconda)\"'"
  clean_env
fi

say "What a batch job sees (for the MODULEPATH-at-login goal)"
# Two shells, because they differ: `sbatch --wrap` runs /bin/sh (dash on
# Ubuntu), which ignores BASH_ENV, while a #!/bin/bash batch script sources it
# and so gets Lmod's `module`. The submitting shell's MODULEPATH is exported
# into the job by default either way.
for sh in /bin/sh /bin/bash; do
  printf '#!%s\n#SBATCH -N1 -t 2 -o batchenv-%s.out\n' "$sh" "$(basename $sh)" > "batchenv-$(basename $sh).sbatch"
  cat >> "batchenv-$(basename $sh).sbatch" <<'JOB'
if command -v module >/dev/null 2>&1 || type module >/dev/null 2>&1; then echo "module: available"; else echo "module: NOT available"; fi
echo "MODULEPATH=${MODULEPATH:-<unset>}"
JOB
  sbatch --wait "batchenv-$(basename $sh).sbatch" >/dev/null 2>&1
  echo "  ${sh} batch script:"; sed 's/^/    /' "batchenv-$(basename $sh).out" 2>/dev/null
done

say "RESULT"
printf '  %s\n' "${R[@]}"
nf="$(printf '%s\n' "${R[@]}" | grep -c '^FAIL' || true)"
echo; echo "  ${nf} of ${#R[@]} failed -- outputs kept in $W"
exit $([ "$nf" = 0 ] && echo 0 || echo 1)
