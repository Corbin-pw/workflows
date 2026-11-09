#!/usr/bin/env bash
# 03-create-nodes.sh -- create the Ubuntu 22.04 node containers.
# Run:  sudo ./03-create-nodes.sh           (existing nodes are left alone)
#       sudo ./03-create-nodes.sh --recreate (delete and rebuild all nodes; shared data in /srv is kept)
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log
RECREATE=0; [ "${1:-}" = "--recreate" ] && RECREATE=1

create_node() {
  local n="$1" ip="$2" cpus="$3" mem="$4" pci="${5:-}"
  if lxc info "$n" >/dev/null 2>&1; then
    if [ "$RECREATE" = 1 ]; then warn "deleting $n"; lxc delete -f "$n"
    else ok "$n exists -- skipping (use --recreate to rebuild)"; return; fi
  fi
  say "Creating $n ($ip, ${cpus} CPU, ${mem}${pci:+, GPU $pci})"
  lxc init "$NODE_IMAGE" "$n" -p "$LXD_PROFILE" \
      -c limits.cpu="$cpus" -c limits.memory="$mem" -c limits.memory.swap=false
  lxc config device override "$n" eth0 ipv4.address="$ip"
  case "$LXD_POOL_DRIVER" in zfs|btrfs|lvm) lxc config device override "$n" root size="$NODE_ROOT_SIZE" ;; esac
  if [ -n "$pci" ]; then
    lxc config device add "$n" gpu0 gpu gputype=physical pci="$pci"
    # Injects the HOST driver's userspace (nvidia-smi, libcuda, NVML) into the node.
    lxc config set "$n" nvidia.runtime=true nvidia.driver.capabilities=compute,utility
  fi
  lxc start "$n"
}

create_node "$CONTROLLER" "$CONTROLLER_IP" "$CTL_CPUS" "$CTL_MEM" ""
for i in "${!COMPUTES[@]}"; do
  create_node "${COMPUTES[$i]}" "${COMPUTE_IPS[$i]}" "$COMPUTE_CPUS" "$COMPUTE_MEM" "${GPU_PCI[$i]:-}"
done

say "Waiting for boot + network"
for n in "${ALL_NODES[@]}"; do
  for _ in $(seq 1 60); do
    lxc exec "$n" -- cloud-init status 2>/dev/null | grep -qE 'done|disabled' && break; sleep 2
  done
  if lxc exec "$n" -- curl -sS -m 10 -o /dev/null https://github.com 2>/dev/null; then ok "$n: booted, internet OK"
  else fail "$n: no internet (bridge NAT / Docker FORWARD / ufw -- see README troubleshooting)"; fi
  if lxc exec "$n" -- test -e /dev/nvidiactl 2>/dev/null; then
    lxc exec "$n" -- nvidia-smi -L 2>&1 | sed "s/^/  $n: /"
  fi
done

say "Nodes"
lxc list -c ns4t
ok "next: sudo ./04-provision-nodes.sh"
echo "Log saved: $TB_LOG"
