#!/usr/bin/env bash
# 02-host-lxd.sh -- LXD, a dedicated bridge + storage pool + node profile, and
# the host directories that become /software and /home in every node.
# Run:  sudo ./02-host-lxd.sh        (idempotent; safe to re-run)
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log

say "LXD"
if ! snap list lxd >/dev/null 2>&1; then
  snap install lxd --channel="$LXD_CHANNEL"
else
  # Ubuntu 22.04 cloud images ship an older LXD snap (4.x/5.0). Refresh it to
  # the LTS track while no instances exist; leave it alone once nodes are up.
  track="$(snap list lxd | awk 'NR==2{print $4}')"
  if [ "${track%%/*}" != "${LXD_CHANNEL%%/*}" ] && [ -z "$(lxc list -c n --format csv 2>/dev/null)" ]; then
    warn "LXD snap tracks '${track}'; refreshing to ${LXD_CHANNEL}"
    snap refresh lxd --channel="$LXD_CHANNEL"
  fi
fi
lxd waitready --timeout=60
ok "LXD $(lxd --version)"
if [ -n "${SUDO_USER:-}" ] && ! id -nG "$SUDO_USER" | grep -qw lxd; then
  usermod -aG lxd "$SUDO_USER"; warn "added $SUDO_USER to group lxd (log out/in to use lxc without sudo)"
fi

say "Storage pool ${LXD_POOL} (${LXD_POOL_DRIVER})"
lxc storage show "$LXD_POOL" >/dev/null 2>&1 || lxc storage create "$LXD_POOL" "$LXD_POOL_DRIVER"
lxc storage info "$LXD_POOL" | sed -n '1,8p'

say "Bridge ${LXD_BRIDGE} (${LXD_SUBNET}, NAT, no IPv6)"
lxc network show "$LXD_BRIDGE" >/dev/null 2>&1 || \
  lxc network create "$LXD_BRIDGE" ipv4.address="$LXD_SUBNET" ipv4.nat=true ipv6.address=none \
      dns.domain="${CLUSTER_NAME}.lan"
lxc network get "$LXD_BRIDGE" ipv4.address

say "Profile ${LXD_PROFILE}"
lxc profile show "$LXD_PROFILE" >/dev/null 2>&1 || lxc profile create "$LXD_PROFILE"
lxc profile edit "$LXD_PROFILE" <<YAML
description: ${CLUSTER_NAME} Slurm node (Ubuntu 22.04 system container)
config:
  # Apptainer and enroot need nested user namespaces / mounts inside the node.
  security.nesting: "true"
  security.syscalls.intercept.mknod: "true"
  security.syscalls.intercept.setxattr: "true"
  boot.autostart: "true"
devices:
  root:
    type: disk
    path: /
    pool: ${LXD_POOL}
  eth0:
    type: nic
    network: ${LXD_BRIDGE}
    name: eth0
  software:
    type: disk
    source: ${HOST_SOFTWARE}
    path: /software
    shift: "true"
  home:
    type: disk
    source: ${HOST_HOME}
    path: /home
    shift: "true"
YAML
ok "profile written (nesting, shared /software and /home with idmapped shift)"

say "Host directories"
mkdir -p "$HOST_SOFTWARE/spack" "$HOST_HOME"
if [ -n "${HOST_SCRATCH:-}" ]; then
  # Azure's temp disk is wiped on deallocate; this unit recreates the directory
  # at every boot, before LXD starts, so the nodes' /scratch mount never dangles.
  cat > /etc/systemd/system/tb-scratch.service <<UNIT
[Unit]
Description=Create ${HOST_SCRATCH} for the ${CLUSTER_NAME} testbed
After=local-fs.target
Before=snap.lxd.daemon.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mkdir -p ${HOST_SCRATCH} && chmod 1777 ${HOST_SCRATCH}'
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload && systemctl enable --now tb-scratch.service
  lxc profile device show "$LXD_PROFILE" | grep -q '^scratch:' || \
    lxc profile device add "$LXD_PROFILE" scratch disk source="$HOST_SCRATCH" path=/scratch shift=true
  ok "/scratch -> $HOST_SCRATCH (ephemeral, 1777)"
fi
chmod 755 "$HOST_BASE" "$HOST_SOFTWARE" "$HOST_HOME"
# /software stays root-owned like on a real cluster; the Spack root under it is
# owned by the cluster user so the workflow runs without sudo. With shift=true,
# host UID N == container UID N, so plain numeric ownership is enough.
chown "${CLUSTER_UID}:${CLUSTER_GID}" "$HOST_SOFTWARE/spack"
ls -ldn "$HOST_SOFTWARE" "$HOST_SOFTWARE/spack" "$HOST_HOME"

say "Firewall interactions"
if command -v docker >/dev/null 2>&1; then
  # Docker sets FORWARD policy DROP; without these rules the nodes boot but
  # cannot reach apt/github -- a silent failure.
  cat > /etc/systemd/system/tb-lxd-forward.service <<UNIT
[Unit]
Description=Allow ${LXD_BRIDGE} forwarding past Docker's FORWARD DROP
After=docker.service snap.lxd.daemon.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -i ${LXD_BRIDGE} -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i ${LXD_BRIDGE} -j ACCEPT; iptables -C DOCKER-USER -o ${LXD_BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -o ${LXD_BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload && systemctl enable --now tb-lxd-forward.service && ok "DOCKER-USER rules for ${LXD_BRIDGE}"
else ok "no Docker"; fi
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow in on "$LXD_BRIDGE"; ufw route allow in on "$LXD_BRIDGE"; ufw route allow out on "$LXD_BRIDGE"
  ok "ufw rules for ${LXD_BRIDGE}"
else ok "ufw inactive"; fi

say "GPUs as LXD sees them"
lxc info --resources | awk '/^GPU/{p=1} p&&/^[A-Z]/&&!/^GPU/{p=0} p' | grep -E 'Card|PCI address|Vendor|Product|NVIDIA|CUDA|driver' | sed 's/^/  /'
echo
echo "  config.env GPU_PCI=(${GPU_PCI[*]:-<empty>})"
for p in $(printf '%s\n' "${GPU_PCI[@]}" | sort -u); do
  [ -n "$p" ] || continue
  if lspci -s "$p" 2>/dev/null | grep -q NVIDIA; then ok "GPU_PCI $p is $(lspci -s "$p" | cut -d' ' -f2-)"
  else warn "GPU_PCI entry '$p' is not an NVIDIA device on this host -- fix config.env before 03"; fi
done

ok "host ready -- next: sudo ./03-create-nodes.sh"
echo "Log saved: $TB_LOG"
