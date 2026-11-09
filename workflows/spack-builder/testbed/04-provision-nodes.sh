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
wait $(jobs -p)

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
say "Slurm packages"
. "${TB_DIR}/lib/slurm.sh"
if tb_slurm_is_source_build; then
  # 04b replaced the apt Slurm with a source build (PMIx). Installing the apt
  # packages again would put a second, older Slurm over it.
  ok "source-built Slurm present ($(tb_slurm_version)) -- leaving it in place"
else
  nexec "$CONTROLLER" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq slurmctld slurm-client >/dev/null"
  for c in "${COMPUTES[@]}"; do
    nexec "$c" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq slurmd slurm-client >/dev/null" &
  done
  wait $(jobs -p)
  ok "slurm $(lxc exec "$CONTROLLER" -- dpkg-query -W -f="\${Version}" slurmctld) (Ubuntu apt)"
fi

# ---------------------------------------------------------------------------
say "Generating slurm.conf + gres.conf"
tb_slurm_configure "04-provision-nodes.sh"

ok "cluster provisioned -- next: sudo ./04b-slurm-pmix.sh (PMIx Slurm, matches the customer) or ./05-verify-cluster.sh"
echo "Log saved: $TB_LOG"
