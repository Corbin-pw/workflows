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
lxc file push "${TB_DIR}/lib/stack-tests.sh" "$CONTROLLER/tmp/stack-tests.sh" --uid "$CLUSTER_UID" --gid "$CLUSTER_GID" --mode 0755
lxc exec "$CONTROLLER" -- runuser -l "$CLUSTER_USER" -c "bash /tmp/stack-tests.sh ${1:-}"
rc=$?
echo "Log saved: $TB_LOG"
exit $rc
