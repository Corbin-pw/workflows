#!/usr/bin/env bash
# 99-destroy.sh -- tear the testbed down.
# Run:  sudo ./99-destroy.sh            delete the node containers only (keeps /srv data: Spack, homes, munge key)
#       sudo ./99-destroy.sh --purge    also delete the bridge, pool, profile and ${HOST_BASE}
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log
read -r -p "Delete nodes ${ALL_NODES[*]}$( [ "${1:-}" = --purge ] && echo " AND ${HOST_BASE} + LXD bridge/pool/profile")? type yes: " a
[ "$a" = yes ] || die "aborted"
for n in "${ALL_NODES[@]}"; do lxc delete -f "$n" 2>/dev/null && ok "deleted $n" || true; done
if [ "${1:-}" = --purge ]; then
  lxc profile delete "$LXD_PROFILE" 2>/dev/null || true
  lxc network delete "$LXD_BRIDGE" 2>/dev/null || true
  lxc storage delete "$LXD_POOL" 2>/dev/null || true
  rm -rf --one-file-system "$HOST_BASE" && ok "removed $HOST_BASE"
fi
