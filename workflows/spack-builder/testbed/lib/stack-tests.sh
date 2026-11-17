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
    [ "$(cat "$d/build/BUILD_STATUS" 2>/dev/null)" = 0 ] && [ -s "$d/modulepath.env" ] && RUN="${d%/}"
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
modname() { module -t avail "$1" 2>&1 | grep -E "^$1/." | grep -E "${2:-.}" | head -1; }
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

for M in openmpi mpich intel-oneapi-mpi; do
  say "$M"
  MOD="$(modname "$M")"
  check "$M: module present (${MOD:-none})" test -n "$MOD"
  [ -n "$MOD" ] || continue
  clean_env; module load "$GCC_MOD" "$MOD"; LOADED="$MOD"
  check "$M: mpicc compiles with gcc 14" bash -c "mpicc --version 2>&1 | head -1 | grep -q ' 14\.' && mpicc -o hello_$M hello.c"
  launchers="$M"; [ "$M" = openmpi ] && launchers="openmpi openmpi-mpirun"
  for L in $launchers; do
    check "$M: hello, ${N1} nodes x ${PPN} ranks via ${L}" bash -c "$(declare -f launch ranks_ok); N1=$N1 PPN=$PPN; launch $L $N1 $PPN ./hello_$M > hello_$L.out 2>&1; cat hello_$L.out; ranks_ok hello_$L.out"
  done
  OSU="$(spack -e "$ENV_DIR" find --format '{prefix}' "osu-micro-benchmarks ^$M" 2>/dev/null | head -1)"
  if [ -n "$OSU" ]; then
    B="$OSU/libexec/osu-micro-benchmarks/mpi/pt2pt"
    check "$M: osu_latency between nodes" bash -c "$(declare -f launch); launch $M 2 1 $B/osu_latency -m 8:1048576 > osu_lat_$M.out 2>&1; cat osu_lat_$M.out; grep -qE '^1048576' osu_lat_$M.out"
    check "$M: osu_bw between nodes"      bash -c "$(declare -f launch); launch $M 2 1 $B/osu_bw -m 1048576:4194304 > osu_bw_$M.out 2>&1; cat osu_bw_$M.out; grep -qE '^4194304' osu_bw_$M.out"
  else R+=("FAIL  $M: no osu-micro-benchmarks in the environment"); fi
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
    check "$node: MODULEPATH has $TREE at login and openmpi loads" \
      srun -w "$node" -N1 -n1 -t 2 --export=NONE bash -lc \
        "echo \$MODULEPATH; case :\$MODULEPATH: in *:$TREE:*) ;; *) exit 1;; esac; module load openmpi && command -v mpicc"
  done
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
