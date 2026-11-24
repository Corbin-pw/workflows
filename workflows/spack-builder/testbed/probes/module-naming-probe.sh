#!/usr/bin/env bash
# probes/module-naming-probe.sh -- read-only experiment for the "update in
# place" work: regenerate the newest GPU run's modules into a SCRATCH tree with
#   hash_length: 0 + hide_implicits: true   (instead of the GPU path's hash_length 7)
# and report whether Spack sees name clashes, what users would see in
# `module avail`, and whether Lmod honours the hidden (implicit) modules and
# still autoloads them. Touches nothing outside /scratch/naming-probe.
# Run:  sudo ./probes/module-naming-probe.sh [RUN_DIR]
TB_LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log
set +e
REMOTE="/tmp/naming-probe-$(date +%s).sh"
lxc exec "$CONTROLLER" -- sh -c "cat > $REMOTE && chown ${CLUSTER_UID}:${CLUSTER_GID} $REMOTE && chmod 0755 $REMOTE" <<'INNER' || die "could not copy the probe into ${CONTROLLER}"
#!/usr/bin/env bash
type module >/dev/null 2>&1 || . /usr/share/lmod/lmod/init/bash
RUN="${1:-}"
if [ -z "$RUN" ]; then
  for d in $(ls -d ~/pw/jobs/*/*/ 2>/dev/null | sort); do
    [ "$(cat "$d/build/BUILD_STATUS" 2>/dev/null)" = 0 ] && grep -qE '^\s*- cuda\s*$' "$d/spack-env/spack.yaml" 2>/dev/null && RUN="${d%/}"
  done
fi
[ -n "$RUN" ] || { echo "no successful GPU build found"; exit 2; }
SPROOT="$(set +u; . "$RUN/inputs.sh" >/dev/null 2>&1; echo "${service_install_prefix:-$HOME/spack}")"
. "$SPROOT/share/spack/setup-env.sh"
P=/scratch/naming-probe; rm -rf "$P"; mkdir -p "$P/env"
cp "$RUN/spack-env/spack.yaml" "$RUN/spack-env/spack.lock" "$P/env/"
echo "== run: $RUN"; echo "== lmod: $(module --version 2>&1 | grep -oE 'Version [0-9.]+[^ ]*' | head -1)"
# `spack python -` does not read a script from stdin, so write it to a file.
cat > "$P/edit.py" <<'PY'
import sys, yaml
path, root = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(path))
m = d["spack"]["modules"]
m["default"]["roots"]["tcl"] = root
m["default"]["arch_folder"] = False
t = m["default"]["tcl"]
print("was: hash_length=%s hide_implicits=%s" % (t.get("hash_length"), t.get("hide_implicits")))
t["hash_length"] = 0
t["hide_implicits"] = True
print("projections:", t.get("projections"))
yaml.safe_dump(d, open(path, "w"), default_flow_style=False, sort_keys=False)
PY
spack python "$P/edit.py" "$P/env/spack.yaml" "$P/modules"
echo "== refresh with hash_length 0 + hide_implicits"
if spack -e "$P/env" module tcl refresh -y > "$P/refresh.log" 2>&1; then echo "REFRESH: OK"; else echo "REFRESH: FAILED"; fi
grep -A3 -E 'clash|file:|Error' "$P/refresh.log" | head -40
echo "== files: $(find "$P/modules" -type f ! -name '.*' | wc -l) modulefiles; hidden entries: $(cat "$P"/modules/*/.modulerc "$P"/modules/.modulerc 2>/dev/null | grep -c 'module-hide')"
echo "== a .modulerc:"; ls "$P"/modules/*/.modulerc 2>/dev/null | head -1 | xargs -r cat
export MODULEPATH="$P/modules"
echo "== module avail (what a user sees):"; module -t avail 2>&1 | grep -v ':$' | sed 's/^/   /'
G="$(module -t avail gromacs 2>&1 | grep -- '-cuda' | head -1)"
echo "== module load $G, then list (hidden deps should be loaded):"
module load "$G" 2>&1 | head -5; module -t list 2>&1 | sed 's/^/   /'; command -v gmx_mpi
module purge >/dev/null 2>&1
echo "== module load git (tk is a hidden dependency):"; module load git 2>&1 | head -3; module -t list 2>&1 | sed 's/^/   /'
echo "== done; scratch tree kept at $P"
INNER
lxc exec "$CONTROLLER" -- runuser -l "$CLUSTER_USER" -c "bash $REMOTE ${1:-}"
rc=$?
lxc exec "$CONTROLLER" -- rm -f "$REMOTE"
echo "Log saved: $TB_LOG"
exit $rc
