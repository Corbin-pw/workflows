#!/usr/bin/env bash
# 04-provision-nodes.sh -- turn the containers into a Slurm cluster.
#   all nodes : base build toolchain, Lmod, sshd, /etc/hosts, cluster user, munge
#   controller: slurmctld (+ login node role)
#   computes  : slurmd, GPU gres
# Run:  sudo ./04-provision-nodes.sh     (idempotent; re-run after editing config.env)
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

# ---------------------------------------------------------------------------
say "Base packages on every node (parallel)"
# What a typical HPC login/compute image carries, and what the spack-builder
# workflow expects to find (gcc/g++/gfortran, make, git, curl, python3, patch...).
# Deliberately NOT installed: slurm/pmix dev headers -- the workflow's header
# probe should see the same thing it will see at the customer (README: open questions).
BASE_PKGS="build-essential gfortran git curl wget ca-certificates python3 python3-venv python3-pip \
 unzip bzip2 xz-utils zstd file patch rsync jq openssh-server openssh-client sudo less vim tmux \
 munge libmunge2 locales tzdata pciutils numactl hwloc gnupg lsb-release ${MODULES_PKG}"
for n in "${ALL_NODES[@]}"; do
  ( lxc exec "$n" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && \
      apt-get install -y -qq $BASE_PKGS >/tmp/apt-base.log 2>&1 && echo '  [ OK ] $n base packages' \
      || { echo '  [FAIL] $n base packages'; tail -20 /tmp/apt-base.log; exit 1; }" ) &
done
wait

# ---------------------------------------------------------------------------
say "/etc/hosts"
{
  echo "# --- ${CLUSTER_NAME} testbed (managed by 04-provision-nodes.sh) ---"
  echo "${CONTROLLER_IP} ${CONTROLLER}"
  for i in "${!COMPUTES[@]}"; do echo "${COMPUTE_IPS[$i]} ${COMPUTES[$i]}"; done
  echo "# --- end ${CLUSTER_NAME} ---"
} > "$STAGE/hosts.block"
for n in "${ALL_NODES[@]}"; do
  lxc file push "$STAGE/hosts.block" "$n/tmp/hosts.block"
  nexec "$n" "sed -i '/# --- ${CLUSTER_NAME} testbed/,/# --- end ${CLUSTER_NAME} ---/d' /etc/hosts; cat /tmp/hosts.block >> /etc/hosts"
done
ok "hosts written"

# ---------------------------------------------------------------------------
say "Cluster user ${CLUSTER_USER} (${CLUSTER_UID}:${CLUSTER_GID}), shared /home"
for n in "${ALL_NODES[@]}"; do
  nexec "$n" "getent group ${CLUSTER_GID} >/dev/null || groupadd -g ${CLUSTER_GID} ${CLUSTER_USER}
    if ! id ${CLUSTER_USER} >/dev/null 2>&1; then
      if [ -d /home/${CLUSTER_USER} ]; then useradd -M -d /home/${CLUSTER_USER} -u ${CLUSTER_UID} -g ${CLUSTER_GID} -s /bin/bash ${CLUSTER_USER}
      else useradd -m -u ${CLUSTER_UID} -g ${CLUSTER_GID} -s /bin/bash ${CLUSTER_USER}; fi
    fi"
  if [ "$CLUSTER_USER_SUDO" = yes ]; then
    nexec "$n" "echo '${CLUSTER_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${CLUSTER_USER} && chmod 440 /etc/sudoers.d/90-${CLUSTER_USER}"
  fi
done
# Passwordless ssh between nodes for the cluster user (shared home => one key).
nexec "$CONTROLLER" "sudo -u ${CLUSTER_USER} bash -c '
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N \"\" -f ~/.ssh/id_ed25519
  grep -qf ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys 2>/dev/null || cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  grep -q \"Host tb-\" ~/.ssh/config 2>/dev/null || printf \"Host tb-* ${CONTROLLER} ${COMPUTES[*]}\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile ~/.ssh/known_hosts\n\" >> ~/.ssh/config
  chmod 600 ~/.ssh/config'"
ok "user + ssh key (/home/${CLUSTER_USER} is shared by all nodes)"

# ---------------------------------------------------------------------------
say "Munge"
[ -f "$HOST_BASE/munge.key" ] || { dd if=/dev/urandom of="$HOST_BASE/munge.key" bs=1 count=1024 status=none; chmod 400 "$HOST_BASE/munge.key"; }
for n in "${ALL_NODES[@]}"; do
  lxc file push "$HOST_BASE/munge.key" "$n/etc/munge/munge.key"
  nexec "$n" "chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key && systemctl enable --now munge >/dev/null 2>&1 && systemctl restart munge"
done
ok "one key on all nodes ($HOST_BASE/munge.key)"

# ---------------------------------------------------------------------------
say "Slurm packages (${SLURM_SOURCE})"
[ "$SLURM_SOURCE" = apt ] || die "SLURM_SOURCE=$SLURM_SOURCE not implemented yet (apt only)"
nexec "$CONTROLLER" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq slurmctld slurm-client >/dev/null"
for c in "${COMPUTES[@]}"; do
  nexec "$c" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq slurmd slurm-client >/dev/null" &
done
wait
SLURM_VER="$(lxc exec "$CONTROLLER" -- sinfo --version | awk '{print $2}')"
ok "slurm ${SLURM_VER}"

# ---------------------------------------------------------------------------
say "Generating slurm.conf + gres.conf"
gpu_dev_of() { lxc exec "$1" -- bash -c 'ls /dev/nvidia[0-9]* 2>/dev/null | head -1'; }
gpu_type_of() { lxc exec "$1" -- nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 \
                | sed -E 's/NVIDIA //; s/GeForce //; s/ PCIe//; s/[^A-Za-z0-9]//g' | tr 'A-Z' 'a-z'; }
mem_mb() { echo $(( $(numfmt --from=iec "${1%iB}") / 1048576 - 1024 )); }   # leave 1 GiB for the OS

NODE_LINES=""; GRES_LINES=""; HAS_GPU=0
for i in "${!COMPUTES[@]}"; do
  c="${COMPUTES[$i]}"; gres=""
  if [ -n "${GPU_PCI[$i]:-}" ]; then
    dev="$(gpu_dev_of "$c")"; typ="$(gpu_type_of "$c")"
    if [ -n "$dev" ] && [ -n "$typ" ]; then
      gres=" Gres=gpu:${typ}:1"; HAS_GPU=1
      GRES_LINES+="NodeName=${c} Name=gpu Type=${typ} File=${dev}"$'\n'
      ok "$c: GPU ${typ} at ${dev}"
    else warn "$c: GPU_PCI set but no /dev/nvidiaN or nvidia-smi inside the node -- no gres"; fi
  fi
  NODE_LINES+="NodeName=${c} NodeAddr=${COMPUTE_IPS[$i]} CPUs=${SLURM_COMPUTE_CPUS:-$COMPUTE_CPUS} RealMemory=$(mem_mb "$COMPUTE_MEM")${gres} State=UNKNOWN"$'\n'
done
cat > "$STAGE/slurm.conf" <<CONF
# slurm.conf -- ${CLUSTER_NAME} testbed, generated by 04-provision-nodes.sh $(date -I)
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${CONTROLLER}(${CONTROLLER_IP})
AuthType=auth/munge
SlurmUser=slurm
StateSaveLocation=/var/lib/slurm/slurmctld
SlurmdSpoolDir=/var/lib/slurm/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
ReturnToService=2
# --- testbed deviations (system containers) -------------------------------
# cgroup-based tracking/confinement inside an unprivileged LXD container is
# fragile, so jobs are tracked by process tree and not CPU/device confined.
# Production most likely uses proctrack/cgroup + task/cgroup,task/affinity.
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
# Trust the CPU/memory below instead of hwloc, which can see all host threads
# through the container's /sys rather than the limits.cpu share.
SlurmdParameters=config_overrides
# --------------------------------------------------------------------------
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU_Memory
DefMemPerCPU=2048
MpiDefault=none
JobAcctGatherType=jobacct_gather/none
AccountingStorageType=accounting_storage/none
$( [ "$HAS_GPU" = 1 ] && echo "GresTypes=gpu" )
# --- nodes ----------------------------------------------------------------
${NODE_LINES}PartitionName=${SLURM_PARTITION} Nodes=ALL Default=YES MaxTime=INFINITE State=UP
CONF
printf '%s' "$GRES_LINES" > "$STAGE/gres.conf"
sed 's/^/  | /' "$STAGE/slurm.conf"; [ -s "$STAGE/gres.conf" ] && sed 's/^/  gres | /' "$STAGE/gres.conf"
cp "$STAGE/slurm.conf" "$STAGE/gres.conf" "$HOST_BASE/"   # keep a copy for the write-up

for n in "${ALL_NODES[@]}"; do
  lxc file push "$STAGE/slurm.conf" "$n/etc/slurm/slurm.conf"
  lxc file push "$STAGE/gres.conf"  "$n/etc/slurm/gres.conf"
  nexec "$n" "mkdir -p /var/lib/slurm/slurmctld /var/lib/slurm/slurmd /var/log/slurm && chown -R slurm:slurm /var/lib/slurm /var/log/slurm && chmod 644 /etc/slurm/*.conf"
done

say "Starting Slurm"
nexec "$CONTROLLER" "systemctl enable slurmctld >/dev/null 2>&1; systemctl restart slurmctld"
for c in "${COMPUTES[@]}"; do nexec "$c" "systemctl enable slurmd >/dev/null 2>&1; systemctl restart slurmd"; done
sleep 5
nexec "$CONTROLLER" "scontrol update nodename=$(IFS=,; echo "${COMPUTES[*]}") state=resume 2>/dev/null || true; sinfo -N -l"

ok "cluster provisioned -- next: sudo ./05-verify-cluster.sh"
echo "Log saved: $TB_LOG"
