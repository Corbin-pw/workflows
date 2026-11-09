#!/usr/bin/env bash
# 05-verify-cluster.sh -- prove the virtual cluster behaves like a real one.
# Run:  sudo ./05-verify-cluster.sh       (read-only apart from a scratch file in /home)
# Ends with a PASS/FAIL table -- paste it back to Claude / into the test log.
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log
set +e   # survey script: keep going past failed probes and report them
declare -a RESULTS
check() { local name="$1"; shift; if out="$("$@" 2>&1)"; then RESULTS+=("PASS  $name"); ok "$name"; else RESULTS+=("FAIL  $name"); fail "$name"; echo "$out" | tail -5 | sed 's/^/        /'; fi; }
asu() { local n="$1"; shift; lxc exec "$n" -- runuser -l "$CLUSTER_USER" -c "$*"; }

say "Node facts"
for n in "${ALL_NODES[@]}"; do
  lxc exec "$n" -- bash -c '. /etc/os-release; printf "  %-8s %-18s kernel=%s nproc=%s mem=%s\n" "$(hostname)" "$PRETTY_NAME" "$(uname -r)" "$(nproc)" "$(free -g | awk "/Mem:/{print \$2}")G"'
done

say "Per-node checks"
for n in "${ALL_NODES[@]}"; do
  check "$n: Ubuntu 22.04"            lxc exec "$n" -- grep -q 'VERSION_ID="22.04"' /etc/os-release
  check "$n: internet (github.com)"   lxc exec "$n" -- curl -sS -m 10 -o /dev/null https://github.com
  check "$n: munge self-test"         lxc exec "$n" -- bash -c 'munge -n | unmunge >/dev/null'
  check "$n: /software mounted"       lxc exec "$n" -- mountpoint -q /software
  [ -n "${HOST_SCRATCH:-}" ] && check "$n: /scratch writable by ${CLUSTER_USER}" asu "$n" "touch /scratch/.w-\$(hostname) && rm /scratch/.w-\$(hostname)"
  check "$n: /software/spack writable by ${CLUSTER_USER}" asu "$n" "touch /software/spack/.w-\$(hostname) && rm /software/spack/.w-\$(hostname)"
  check "$n: module command (${MODULES_PKG})" asu "$n" "type module >/dev/null"
  check "$n: unprivileged userns (apptainer prerequisite)" asu "$n" "unshare -Ur true"
done

say "Cross-node checks"
c1="${COMPUTES[0]}"; c2="${COMPUTES[1]:-${COMPUTES[0]}}"
check "munge credential from $c1 decodes on $CONTROLLER" bash -c "lxc exec $c1 -- munge -n | lxc exec $CONTROLLER -- unmunge >/dev/null"
check "shared /home: file from $c1 visible on $c2 with same owner" bash -c \
  "lxc exec $c1 -- sudo -u $CLUSTER_USER bash -c 'echo hi > ~/.tb-shared-test' && \
   [ \"\$(lxc exec $c2 -- stat -c %u /home/$CLUSTER_USER/.tb-shared-test)\" = $CLUSTER_UID ] && \
   lxc exec $c2 -- rm -f /home/$CLUSTER_USER/.tb-shared-test"
check "ssh $CONTROLLER -> $c1 as ${CLUSTER_USER} (no password)" asu "$CONTROLLER" "ssh -o BatchMode=yes $c1 hostname"

say "Slurm"
lxc exec "$CONTROLLER" -- sinfo -N -o '%N %T %c %m %G' | sed 's/^/  /'
check "all compute nodes idle"         bash -c "! lxc exec $CONTROLLER -- sinfo -h -N -o '%T' | grep -vqE '^(idle|mixed|allocated)$'"
check "srun on every compute node"     asu "$CONTROLLER" "srun -N${#COMPUTES[@]} -t 1 hostname | sort | tr '\n' ' '"
check "sbatch round trip"              asu "$CONTROLLER" 'cd ~ && j=$(sbatch --parsable -t 1 --wrap "hostname > tb-sbatch.out") && for i in $(seq 30); do squeue -h -j $j | grep -q . || break; sleep 1; done; grep -q tb-c tb-sbatch.out && rm tb-sbatch.out'
echo "  srun --mpi=list: $(lxc exec "$CONTROLLER" -- srun --mpi=list 2>&1 | tr '\n' ' ')"
echo "  Slurm: $(lxc exec "$CONTROLLER" -- slurmctld -V 2>/dev/null) ($(lxc exec "$CONTROLLER" -- test -f /etc/slurm/.tb-source-build && echo source build || echo Ubuntu apt)), MpiDefault=$(lxc exec "$CONTROLLER" -- scontrol show config 2>/dev/null | awk '/^MpiDefault/{print $3}')"
if [ "${SLURM_PMIX:-no}" = yes ]; then
  check "Slurm has the PMIx plugin (srun --mpi=list)" bash -c "lxc exec $CONTROLLER -- srun --mpi=list 2>&1 | grep -q pmix"
  check "srun --mpi=pmix starts one rank per node" asu "$CONTROLLER" "out=\$(srun -N${#COMPUTES[@]} --ntasks-per-node=1 --mpi=pmix -t 1 bash -c 'echo \$SLURMD_NODENAME:\$PMIX_RANK' | sort); echo \$out; [ \$(echo \$out | grep -o ':[0-9]' | wc -l) = ${#COMPUTES[@]} ]"
  check "default srun is PMIx (MpiDefault)" asu "$CONTROLLER" "srun -N1 -t 1 bash -c 'test -n \"\$PMIX_RANK\"'"
fi

say "Development headers (what the workflow's header probe will see)"
# Same roots as app/probe-headers.sh, so this predicts its HDR_* verdicts.
for h in slurm/slurm.h slurm/pmi2.h pmix.h; do
  p="$(lxc exec "${COMPUTES[0]}" -- bash -c "ls /usr/include/$h /usr/local/include/$h 2>/dev/null | head -1")"
  if [ -n "$p" ]; then echo "  present  $h  $p"
  else alt="$(lxc exec "${COMPUTES[0]}" -- bash -c "find /usr /opt -path '*/$h' 2>/dev/null | head -1")"; echo "  MISSING  $h${alt:+  (exists at $alt, outside the probe search roots)}"; fi
done
if [ "${SLURM_PMIX:-no}" = yes ]; then
  check "Slurm headers on compute nodes (assumption A4)" lxc exec "${COMPUTES[0]}" -- test -f /usr/include/slurm/slurm.h -a -f /usr/include/slurm/pmi2.h
fi

say "GPUs"
for i in "${!COMPUTES[@]}"; do
  c="${COMPUTES[$i]}"; [ -n "${GPU_PCI[$i]:-}" ] || { echo "  $c: no GPU configured"; continue; }
  check "$c: nvidia-smi inside node" lxc exec "$c" -- nvidia-smi -L
  check "$c: GPU through Slurm (--gres=gpu:1)" asu "$CONTROLLER" "srun -w $c --gres=gpu:1 -t 1 nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader"
  asu "$CONTROLLER" "srun -w $c --gres=gpu:1 -t 1 bash -c 'echo CUDA_VISIBLE_DEVICES=\$CUDA_VISIBLE_DEVICES; nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader'" 2>&1 | sed "s/^/  $c: /"
done

say "RESULT"
printf '  %s\n' "${RESULTS[@]}"
nfail="$(printf '%s\n' "${RESULTS[@]}" | grep -c '^FAIL' || true)"
echo; [ "$nfail" = 0 ] && ok "all ${#RESULTS[@]} checks passed -- next: Activate agent (06)" || fail "${nfail} of ${#RESULTS[@]} checks failed"
echo "Log saved: $TB_LOG"
exit "$([ "$nfail" = 0 ] && echo 0 || echo 1)"
