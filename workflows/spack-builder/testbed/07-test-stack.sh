#!/usr/bin/env bash
# 07-test-stack.sh -- test a stack spack-builder built on the testbed, the way
# users will use it: modules, compile, MPI across both compute nodes with each
# MPI and its launcher, OSU latency/bandwidth, a real GROMACS run per MPI, and
# what a batch job's environment contains. ~10 minutes. Read-only apart from a
# work directory in /scratch.
# Run:  sudo ./07-test-stack.sh [RUN_DIR]   (default: newest successful full build)
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log
set +e
# Streamed through stdin rather than `lxc file push`: the snap's file push read
# the script through /var/lib/snapd/hostfs and was refused ("Error: Forbidden"),
# and this script then ran the copy left by the previous run without saying so.
# A fresh name per run makes a stale copy impossible; a failed copy is fatal.
REMOTE="/tmp/stack-tests-$(date +%s).sh"
if ! lxc exec "$CONTROLLER" -- sh -c "cat > $REMOTE && chown ${CLUSTER_UID}:${CLUSTER_GID} $REMOTE && chmod 0755 $REMOTE" < "${TB_DIR}/lib/stack-tests.sh"; then
  die "could not copy lib/stack-tests.sh into ${CONTROLLER}"
fi
want="$(sha256sum < "${TB_DIR}/lib/stack-tests.sh" | cut -c1-16)"
got="$(lxc exec "$CONTROLLER" -- sh -c "sha256sum < $REMOTE" | cut -c1-16)"
[ "$want" = "$got" ] || die "copy of lib/stack-tests.sh in ${CONTROLLER} does not match (${got} vs ${want})"
ok "test script copied to ${CONTROLLER}:${REMOTE} (sha256 ${want})"
lxc exec "$CONTROLLER" -- runuser -l "$CLUSTER_USER" -c "bash $REMOTE ${1:-}"
rc=$?
lxc exec "$CONTROLLER" -- rm -f "$REMOTE"
echo "Log saved: $TB_LOG"
exit $rc
