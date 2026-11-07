# shellcheck shell=bash
# lib/common.sh -- helpers sourced by every testbed script.
set -euo pipefail
TB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "${TB_DIR}/config.env" ] || { echo "ERROR: ${TB_DIR}/config.env is missing" >&2; exit 1; }
. "${TB_DIR}/config.env"
ALL_NODES=("$CONTROLLER" "${COMPUTES[@]}")

# Log every script run to logs/<script>-<timestamp>.log as well as the terminal,
# so each step leaves a record for the test/dev write-up.
tb_start_log() {
  mkdir -p "${TB_DIR}/logs"
  local name; name="$(basename "$0" .sh)"
  TB_LOG="${TB_DIR}/logs/${name}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$TB_LOG") 2>&1
  echo "### $(basename "$0") on $(hostname) at $(date -Is) -- log: $TB_LOG"
}
say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 $*"; }
# Run a command inside a node as root.
nexec() { local n="$1"; shift; lxc exec "$n" -- bash -lc "$*"; }
