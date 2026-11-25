#!/usr/bin/env bash
# probes/module-naming-probe.sh -- read-only experiment for the "update in
# place" work: regenerate the newest GPU run's modules into a SCRATCH tree with
# NO hash suffix (the GPU path uses hash_length 7) and report whether Spack sees
# name clashes and whether the modules still load and autoload.
# Round 1 (hide_implicits) is out: Lmod 6.6, Ubuntu 22.04's, aborts on the
# `module-hide` lines Spack writes ("invalid command name module-hide").
# Round 2: hash_length 0, everything visible, plus one projection for builds
# against a CUDA hwloc (pmix, prrte: identical variants, differing only in
# hwloc, the reason the GPU path needed hashes). Touches nothing outside
# /scratch/naming-probe.
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
    # A dry run (concretize_only) also exits 0 and writes modulepath.env, but
    # installs and generates nothing: never pick one by default.
    [ "$(cat "$d/build/BUILD_STATUS" 2>/dev/null)" = 0 ] && grep -qE '^\s*- cuda\s*$' "$d/spack-env/spack.yaml" 2>/dev/null && ! grep -qs 'service_concretize_only="true"' "$d/inputs.sh" && RUN="${d%/}"
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
t.pop("hide_implicits", None)
proj = {}
for k, v in (t.get("projections") or {}).items():
    proj[k] = v
    if k == "+cuda":   # first match wins: after the +cuda rules, before ^mpi/all
        proj["^hwloc+cuda"] = "{name}/{version}-{compiler.name}-{compiler.version}-cuda"
t["projections"] = proj
print("projections:", proj)
yaml.safe_dump(d, open(path, "w"), default_flow_style=False, sort_keys=False)
PY
spack python "$P/edit.py" "$P/env/spack.yaml" "$P/modules"
echo "== refresh with hash_length 0 + the ^hwloc+cuda projection"
if spack -e "$P/env" module tcl refresh -y > "$P/refresh.log" 2>&1; then echo "REFRESH: OK"; else echo "REFRESH: FAILED"; fi
if grep -q 'file:' "$P/refresh.log"; then
  echo "== $(grep -c 'file:' "$P/refresh.log") clashing module name(s), each with the specs that collide:"
  grep -E 'file:|spec:' "$P/refresh.log" | sed -E 's#/scratch/naming-probe/modules/##; s/ arch=[^ ]*//' | cut -c1-200
  echo "== done (refresh failed; nothing to load)"; exit 0
fi
echo "== files: $(find "$P/modules" -type f ! -name '.*' | wc -l) modulefiles; with -cuda: $(find "$P/modules" -type f -name '*-cuda' | wc -l)"
echo "== -cuda modules:"; (cd "$P/modules" && find . -type f -name '*-cuda' | sed 's#^\./#   #' | sort)
export MODULEPATH="$P/modules"
echo "== module avail: $(module -t avail 2>&1 | grep -vc ':$') entries; errors: $(module -t avail 2>&1 | grep -ciE 'error|abort|invalid')"
echo "== the MPI-related ones:"; module -t avail 2>&1 | grep -E '^(gromacs|openmpi|mpich|intel-oneapi-mpi|pmix|prrte|hwloc|ucx|osu-micro-benchmarks)/' | sed 's/^/   /'
G="$(module -t avail gromacs 2>&1 | grep -- '-cuda' | head -1)"
echo "== module load $G, then list (its dependencies should autoload):"
module load "$G" 2>&1 | head -5; module -t list 2>&1 | sed 's/^/   /'; command -v gmx_mpi
module purge >/dev/null 2>&1
echo "== module load git (tk should autoload):"; module load git 2>&1 | head -3; module -t list 2>&1 | sed 's/^/   /'
echo "== done; scratch tree kept at $P"
INNER
lxc exec "$CONTROLLER" -- runuser -l "$CLUSTER_USER" -c "bash $REMOTE ${1:-}"
rc=$?
lxc exec "$CONTROLLER" -- rm -f "$REMOTE"
echo "Log saved: $TB_LOG"
exit $rc
