#!/usr/bin/env bash
# 06-activate-agent.sh -- install the ACTIVATE agent on testbed nodes so the
# cluster registers as an "existing" resource.
#
# 1. In ACTIVATE, add an existing cluster and copy the agent install/start
#    command it gives you (it contains a token -- treat it like a password).
# 2. Save it as testbed/activate-agent.cmd   (git-ignored; never committed or logged).
#    It runs as a bash script, so it can hold the pw CLI install too (README, "ACTIVATE agent"):
#      export PATH="$HOME/pw:$HOME/.local/bin:$PATH"
#      <pw CLI install command>
#      <agent SERVICE install command>   -- service, so it survives node restarts
# 3. Run:  sudo ./06-activate-agent.sh                 -> controller only (the login node)
#          sudo ./06-activate-agent.sh tb-c1 tb-c2     -> specific nodes
#          sudo ./06-activate-agent.sh --all           -> every node
# The command runs as ${CLUSTER_USER} inside each node, i.e. the account that
# workflows will run as. The agent dials OUT to ACTIVATE, so the nodes need
# only the bridge NAT -- no inbound port on the host.
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
CMD_FILE="${TB_DIR}/activate-agent.cmd"
[ -s "$CMD_FILE" ] || die "save the ACTIVATE agent command to $CMD_FILE first"
chmod 600 "$CMD_FILE"
tb_start_log

if [ "${1:-}" = "--all" ]; then TARGETS=("${ALL_NODES[@]}")
elif [ $# -gt 0 ]; then TARGETS=("$@")
else TARGETS=("$CONTROLLER"); fi

for n in "${TARGETS[@]}"; do
  say "Agent on $n (as ${CLUSTER_USER})"
  lxc file push "$CMD_FILE" "$n/tmp/activate-agent.cmd" --uid "$CLUSTER_UID" --gid "$CLUSTER_GID" --mode 0600
  # The command text is not echoed, so the token never lands in logs/.
  if lxc exec "$n" -- sudo -iu "$CLUSTER_USER" bash -l /tmp/activate-agent.cmd; then ok "$n: agent command finished"
  else fail "$n: agent command exited non-zero (output above)"; fi
  lxc exec "$n" -- rm -f /tmp/activate-agent.cmd
  lxc exec "$n" -- sudo -iu "$CLUSTER_USER" bash -lc 'command -v pw >/dev/null && { pw --version; pw auth whoami 2>&1 | head -2; } || ls ~/pw 2>/dev/null' | sed "s/^/  $n: /" || true
done
echo
echo "Next: in ACTIVATE confirm the cluster shows as connected, then run a hello-world workflow on it."
echo "Log saved: $TB_LOG"
