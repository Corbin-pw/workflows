#!/usr/bin/env bash
# install-login-hook.sh [PARTITION] -- put the stack's module tree on every
# user's MODULEPATH at login, on the login node and on every compute node Slurm
# can reach. Runs on the login node, as the workflow user, after the build and
# the execution check have passed.
#
# Two files, so root is needed once and never again:
#   <Spack root>/etc/profile.d/spack-modules.sh   owned by the workflow user,
#       rewritten every run with the current module tree(s); shared filesystem
#   /etc/profile.d/z99-spack-builder-modules.sh    root-owned, node-local, and
#       only sources the first file. Installed with `sudo -n`.
#
# The hook PREPENDS the tree, once: a `module load openmpi` should find the
# site stack before a same-named system module. A batch job inherits
# MODULEPATH from the shell that submitted it, so the login node is the one
# that matters most; compute nodes cover interactive `srun --pty bash -l`.
#
# Consumes (from inputs.sh): service_login_hook, service_install_prefix,
# modulepath_env, PW_RUN_SLUG.
set -uo pipefail
log() { printf '\n=== [login-hook] %s ===\n' "$*"; }
PART="${1:-}"

if [ "${service_login_hook:-false}" != "true" ]; then
  echo "::notice::Login hook not requested: MODULEPATH is left to each user (see the DONE banner of the build)"
  exit 0
fi
if [ ! -s "${modulepath_env:-}" ]; then
  echo "::notice::This run generated no module tree (dry run, or the build stopped before modules): nothing to add at login"
  exit 0
fi

MP="$(cat "$modulepath_env")"
SPACK_ROOT="${service_install_prefix:?service_install_prefix is required}"
HOOK_DIR="$SPACK_ROOT/etc/profile.d"
SHARED_HOOK="$HOOK_DIR/spack-modules.sh"
ROOT_HOOK_SRC="$HOOK_DIR/z99-spack-builder-modules.sh"   # what gets installed as root
ROOT_HOOK="/etc/profile.d/z99-spack-builder-modules.sh"
mkdir -p "$HOOK_DIR"

log "Shared hook $SHARED_HOOK"
tmp="$(mktemp "$HOOK_DIR/.spack-modules.XXXXXX")"
cat > "$tmp" <<HOOK
# spack-modules.sh -- written by the spack-builder workflow, run ${PW_RUN_SLUG:-?}, $(date -u +%FT%TZ).
# Sourced at login by $ROOT_HOOK on every node. Prepends the site Spack
# module tree(s) to MODULEPATH once; safe to source repeatedly. POSIX sh.
_sb_pre=""
for _sb_d in $(printf '%s' "$MP" | tr ':' ' '); do
  case ":\${MODULEPATH:-}:" in *":\$_sb_d:"*) continue ;; esac
  [ -d "\$_sb_d" ] && _sb_pre="\${_sb_pre:+\$_sb_pre:}\$_sb_d"
done
if [ -n "\$_sb_pre" ]; then MODULEPATH="\$_sb_pre\${MODULEPATH:+:\$MODULEPATH}"; export MODULEPATH; fi
unset _sb_pre _sb_d
HOOK
chmod 0644 "$tmp"; mv -f "$tmp" "$SHARED_HOOK"
sed 's/^/  | /' "$SHARED_HOOK"
sh -n "$SHARED_HOOK" || { echo "::error title=Error::generated $SHARED_HOOK is not valid sh" >&2; exit 1; }

cat > "$ROOT_HOOK_SRC" <<HOOK
# z99-spack-builder-modules.sh -- installed by the spack-builder workflow.
# Only sources the hook the workflow maintains in the shared Spack root, so
# changing the module path later never needs root again.
[ -r "$SHARED_HOOK" ] && . "$SHARED_HOOK"
HOOK
chmod 0644 "$ROOT_HOOK_SRC"

install_here() {  # installs ROOT_HOOK on the node it runs on; prints one status word
  if cmp -s "$1" "$2" 2>/dev/null; then echo "unchanged"; return 0; fi
  sudo -n install -m 0644 -o root -g root "$1" "$2" 2>/dev/null && echo "installed" || { echo "sudo-denied"; return 1; }
}

FAIL=0; HOST="$(hostname -s)"
log "Login node $HOST"
st="$(install_here "$ROOT_HOOK_SRC" "$ROOT_HOOK")" || FAIL=1
echo "  $HOST: $st"
[ "$st" = "sudo-denied" ] && echo "::error title=Error::sudo -n was refused on $HOST, so $ROOT_HOOK could not be installed" >&2

log "Compute nodes"
UNREACHED=()
if command -v sinfo >/dev/null 2>&1; then
  mapfile -t NODES < <(sinfo -h -N ${PART:+-p "$PART"} -o '%N %T' 2>/dev/null \
                       | awk '$2 !~ /down|drain|fail|maint|unk|future|powered_down|power_down/ {print $1}' | sort -u)
  for n in "${NODES[@]}"; do
    [ "${n%%.*}" = "$HOST" ] && continue
    out="$(srun -w "$n" -N1 -n1 -c1 --mem=64M -t 2 --immediate=120 ${PART:+-p "$PART"} \
             bash -c "$(declare -f install_here); install_here '$ROOT_HOOK_SRC' '$ROOT_HOOK'" 2>&1)"
    case "$out" in
      *installed*|*unchanged*) echo "  $n: $(printf '%s' "$out" | grep -oE 'installed|unchanged' | tail -1)" ;;
      *sudo-denied*) echo "  $n: sudo-denied"; FAIL=1
                     echo "::error title=Error::sudo -n was refused on $n, so $ROOT_HOOK could not be installed there" >&2 ;;
      *) echo "  $n: not reached ($(printf '%s' "$out" | tail -1))"; UNREACHED+=("$n") ;;
    esac
  done
  [ "${#NODES[@]}" -gt 0 ] || echo "  (sinfo listed no usable nodes${PART:+ in partition $PART})"
  [ "${#UNREACHED[@]}" -eq 0 ] || echo "::warning::Login hook not installed on ${UNREACHED[*]} (busy, down or unreachable within 2 minutes). Re-run, or on each: sudo install -m 0644 $ROOT_HOOK_SRC $ROOT_HOOK"
else
  echo "  no sinfo: login node only"
fi

log "Check: what a NEW login shell sees"
first="${MP%%:*}"
seen="$(env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/bash PATH=/usr/bin:/bin bash -lc 'echo "$MODULEPATH"' 2>/dev/null)"
echo "  $HOST MODULEPATH=$seen"
case ":$seen:" in *":$first:"*) echo "  $HOST: module tree on MODULEPATH at login" ;;
  *) echo "::warning::A fresh login shell on $HOST does not have $first on MODULEPATH -- is /etc/profile.d read by its shells?" ;; esac

[ "$FAIL" = 0 ] || exit 1
echo "::notice::Module tree added at login: $MP (hook $ROOT_HOOK -> $SHARED_HOOK)"
