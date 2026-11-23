#!/usr/bin/env bash
# build-python-envs.sh -- Python virtual environments and the Conda/Mamba
# module, after build.sh has installed the Spack stack and written its modules.
# Sourced inputs (exported by build.sh):
#   SPACK_ROOT, ENV_DIR, MODULE_DIR (one directory of the module tree)
#   service_python_env       "true" to build the environments in python_envs_file
#   service_python_version   e.g. 3.11 -- the Spack python@ every venv is made from
#   python_envs_file         one environment per line: "<name>: <pip requirements>"
#   service_miniforge        "true" to install Miniforge (conda-forge only) + module
#   app_dir                  for tools/utils/miniforge.sh
#
# Why venvs on Spack's Python, not conda: nothing here depends on Anaconda's
# channels or on conda being allowed at a site; PyPI ships every package on the
# list as Linux x86_64 wheels. Why several environments: requirements that
# cannot share one resolver solution get one each -- ESM-3 (`esm`) caps
# transformers below 4.48.2 and pulls the discontinued torchtext, which would
# drag the whole ML environment back, and fair-esm and esm both install the
# import name `esm`.
#
# Updates never replace anything. An environment's directory is named by a
# hash of its Python version and requirements: an unchanged line is reused, a
# changed one builds a NEW directory and a new module version next to the old
# one, and only the module's default moves to the newest.
set -uo pipefail
log() { printf '\n=== [python] %s ===\n' "$*"; }
: "${SPACK_ROOT:?}" "${ENV_DIR:?}" "${MODULE_DIR:?}"
ENVS_ROOT="$SPACK_ROOT/envs"
FAIL=0

# ---------------------------------------------------------------------------
# 1. Python environments
# ---------------------------------------------------------------------------
if [ "${service_python_env:-false}" = "true" ]; then
  PYVER="${service_python_version:-3.11}"
  PY_PREFIX="$(spack -e "$ENV_DIR" find --format '{prefix}' "python@${PYVER}" 2>/dev/null | grep "^${SPACK_ROOT}/opt/" | head -1)"
  PYTHON="$(ls "$PY_PREFIX"/bin/python${PYVER} "$PY_PREFIX"/bin/python3 2>/dev/null | head -1)"
  [ -x "$PYTHON" ] || { echo "::error title=Error::No Spack-built python@${PYVER} in this environment (looked under ${PY_PREFIX:-<none>})" >&2; exit 1; }
  FULLVER="$("$PYTHON" -c 'import platform; print(platform.python_version())')"
  log "Environments on Spack Python ${FULLVER} ($PYTHON)"
  mkdir -p "$ENVS_ROOT"

  # import name for a requirement, for the smoke test; unknown -> normalised name
  import_name() {
    local r; r="$(printf '%s' "$1" | sed -E 's/\[.*//; s/[<>=!~;].*//' | tr 'A-Z' 'a-z')"
    case "$r" in
      biopython) echo Bio ;; scikit-learn) echo sklearn ;; fair-esm) echo esm ;;
      # EvolutionaryScale's esm: its top level imports almost nothing, while
      # esm.sdk needs httpx, which esm 3.2.1 does not declare -- import the
      # modules users actually reach for.
      esm) echo esm.models.esm3; echo esm.sdk.api ;;
      jax-cuda12-plugin|jax-cuda13-plugin) echo jax ;; openmm-cuda-1*) echo openmm ;;
      pyyaml) echo yaml ;; pillow) echo PIL ;; opencv-python*) echo cv2 ;;
      *) printf '%s\n' "$r" | tr '-' '_' ;;
    esac
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
    name="$(printf '%s' "${line%%:*}" | tr -d '[:space:]')"; reqs="${line#*:}"
    case "$name" in ''|*[!A-Za-z0-9._-]*) echo "::error title=Error::bad environment name in '${line}' (use letters, digits, . _ -)" >&2; FAIL=1; continue ;; esac
    [ "$line" != "$name" ] || { echo "::error title=Error::'${line}': expected '<name>: <requirements>'" >&2; FAIL=1; continue; }

    # requirements.in: one token per line; "--option value" pairs stay together
    req_in="$(printf '%s\n' $reqs | awk '/^--/ && !/=/ {printf "%s ", $0; next} {print}')"
    hash="$(printf 'python=%s\n%s\n' "$FULLVER" "$req_in" | sha256sum | cut -c1-8)"
    modver="${PYVER}-${hash}"
    dir="$ENVS_ROOT/py-${name}-${modver}"
    log "${name}-env: $(printf '%s ' $reqs)"
    if [ -f "$dir/.complete" ]; then
      echo "  unchanged -- reusing $dir"
    else
      # Built in place (a venv bakes its own path into bin/ scripts) and sealed
      # with .complete; a directory without the marker is a failed or
      # interrupted build of this exact environment and is redone.
      rm -rf "$dir"
      if ! "$PYTHON" -m venv "$dir"; then echo "::error title=Error::${name}-env: venv creation failed" >&2; FAIL=1; continue; fi
      printf '%s\n' "$req_in" > "$dir/requirements.in"
      "$dir/bin/python" -m pip install -q --upgrade pip
      if ! "$dir/bin/python" -m pip install --retries 5 --timeout 120 -r "$dir/requirements.in" > "$dir/pip-install.log" 2>&1; then
        echo "::error title=Error::${name}-env: pip install failed; last lines:" >&2; tail -30 "$dir/pip-install.log" >&2
        FAIL=1; continue
      fi
      "$dir/bin/python" -m pip check > "$dir/pip-check.log" 2>&1 \
        || { echo "::warning::${name}-env: pip check reports conflicts:"; sed 's/^/    /' "$dir/pip-check.log"; }
      # Imports, on this (build) node. Catches a compiled extension that does
      # not load next to the resolved versions -- torchtext 0.18 was built for
      # torch 2.3 -- which pip resolves without complaint.
      imports="$(for r in $reqs; do case "$r" in --*|http*|./*|/*) ;; *) import_name "$r" ;; esac; done | sort -u | tr '\n' ' ')"
      if ! (cd /tmp && "$dir/bin/python" -c "
import importlib, sys
bad = []
for m in sys.argv[1:]:
    try: importlib.import_module(m)
    except Exception as e: bad.append('%s: %s: %s' % (m, type(e).__name__, str(e).splitlines()[0] if str(e) else ''))
print('imported:', ' '.join(m for m in sys.argv[1:] if not any(b.startswith(m + ':') for b in bad)))
for b in bad: print('IMPORT FAILED', b)
sys.exit(1 if bad else 0)" $imports); then
        echo "::error title=Error::${name}-env: a package installed but does not import (above). Pin a compatible version in its line, e.g. 'torch==2.3.1'." >&2
        FAIL=1; continue
      fi
      "$dir/bin/python" -m pip freeze > "$dir/requirements.lock.txt"
      printf 'name=%s\npython=%s\nrequirements_hash=%s\nbuilt=%s\nrun=%s\n' "$name" "$FULLVER" "$hash" "$(date -u +%FT%TZ)" "${PW_RUN_SLUG:-?}" > "$dir/ENVIRONMENT"
      touch "$dir/.complete"
      echo "  built $dir ($(grep -c '==' "$dir/requirements.lock.txt") packages; lock: $dir/requirements.lock.txt)"
    fi

    # Module <name>-env, not py-<name>: Spack already files its Python
    # PACKAGES as py-* (py-pip, py-cython, ... arrive as build dependencies),
    # and an environment must not look like one of them. Directories on disk
    # keep their py-<name>-* names, so renaming the module rebuilt nothing.
    mdir="$MODULE_DIR/${name}-env"; mkdir -p "$mdir"
    old="$MODULE_DIR/py-${name}"
    if [ -d "$old" ] && grep -qs 'built by spack-builder' "$old"/* ; then rm -rf "$old"; echo "  removed the old module name py-${name} (now ${name}-env)"; fi
    cat > "$mdir/$modver" <<MOD
#%Module1.0
## ${name}-env ${modver}: Python ${FULLVER} virtual environment built by spack-builder
## requirements: $(printf '%s ' $reqs)
## exact versions: ${dir}/requirements.lock.txt
module-whatis "Python ${FULLVER} environment '${name}': $(printf '%s ' $reqs)"
prepend-path PATH ${dir}/bin
setenv VIRTUAL_ENV ${dir}
# Keep ~/.local site-packages out of a shared environment.
setenv PYTHONNOUSERSITE 1
MOD
    printf '#%%Module1.0\nset ModulesVersion "%s"\n' "$modver" > "$mdir/.version"
    echo "  module ${name}-env/${modver} (default); all versions: $(ls "$mdir" | tr '\n' ' ')"
  done < "${python_envs_file:?python_envs_file is required}"
fi

# ---------------------------------------------------------------------------
# 2. Conda/Mamba: Miniforge, conda-forge ONLY.
#    Anaconda's own `defaults` channel needs a paid licence for larger
#    organisations; conda, mamba and conda-forge do not. `default_channels`
#    re-points the name "defaults" at conda-forge, so a user who types
#    `-c defaults` still never reaches repo.anaconda.com. Users' environments
#    and package cache go to their home: the prefix belongs to the workflow.
# ---------------------------------------------------------------------------
if [ "${service_miniforge:-false}" = "true" ]; then
  MF="$ENVS_ROOT/miniforge3"
  log "Miniforge (conda-forge only) at $MF"
  # shellcheck disable=SC1091
  . "${app_dir}/../../../tools/utils/miniforge.sh"
  if ! miniforge_bootstrap "$MF"; then FAIL=1; else
    cat > "$MF/.condarc" <<'RC'
# Written by spack-builder: conda-forge only.
channels:
  - conda-forge
default_channels:
  - https://conda.anaconda.org/conda-forge
channel_priority: strict
envs_dirs:
  - ~/.conda/envs
pkgs_dirs:
  - ~/.conda/pkgs
RC
    [ -x "$MF/bin/mamba" ] && ln -sf ../bin/mamba "$MF/condabin/mamba"
    CV="$("$MF/bin/conda" --version | awk '{print $2}')"
    echo "  conda $CV, mamba $("$MF/bin/mamba" --version 2>/dev/null | head -1 | awk '{print $NF}')"
    echo "  channels: $("$MF/bin/conda" config --show channels 2>/dev/null | tr -d '\n' | sed 's/  */ /g')"
    mkdir -p "$MODULE_DIR/miniforge3"
    cat > "$MODULE_DIR/miniforge3/$CV" <<MOD
#%Module1.0
## miniforge3 ${CV}: conda and mamba, conda-forge channel only (no Anaconda 'defaults').
## Activate environments with:  eval "\$(conda shell.bash hook)"
## Your environments live in ~/.conda/envs.
module-whatis "conda ${CV} + mamba (Miniforge), conda-forge only"
prepend-path PATH ${MF}/condabin
MOD
    printf '#%%Module1.0\nset ModulesVersion "%s"\n' "$CV" > "$MODULE_DIR/miniforge3/.version"
    echo "  module miniforge3/$CV"
  fi
fi

exit "$FAIL"
