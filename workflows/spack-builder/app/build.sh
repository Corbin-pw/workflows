#!/usr/bin/env bash
# build.sh — render, concretize, install and publish the Spack MPI stack.
#
# Runs on the build node: the login node by default (it has internet for source
# fetches and is not subject to a queue walltime), or a worker when the form's
# "Run the build on" is set to a compute node (service_build_on=compute; the
# worker then needs internet too). It does NOT bootstrap Spack and it does NOT
# probe hardware -- controller.sh has already set up the install and
# detect-fabric.sh has already reported what the COMPUTE nodes look like. This
# script only consumes those results.
#
# Consumes (from the sourced inputs.sh):
#   app_dir                  workflows/spack-builder/app, relative to the run dir
#   service_install_prefix   Spack root
#   service_buildcache_path  binary mirror to install from and push to
#   service_build_jobs       -j for builds
#   service_build_gpu        "true" to add the CUDA-aware path
#   fabric_env               path to the fabric.env produced by detection/overrides
#   service_build_on         login | compute -- where this script was sent
#   externals_compute        site externals discovered on the worker (preferred)
#   externals_head           site externals discovered on the login node (fallback)
#
# The stack compiler version is NOT an input: it is read from
# templates/spack.yaml.in so the environment definition stays the only place it
# is written down.

set -euo pipefail
set -o pipefail

APP_DIR="${app_dir:?app_dir is required}"
SPACK_ROOT="${service_install_prefix:?service_install_prefix is required}"
BUILDCACHE_PATH="${service_buildcache_path:?service_buildcache_path is required}"
JOBS="${service_build_jobs:-$(nproc)}"
BUILD_GPU="${service_build_gpu:-false}"
BUILD_ON="${service_build_on:-login}"
FABRIC_ENV="${fabric_env:-${PWD}/fabric.env}"
ENV_DIR="${env_dir:-${PWD}/spack-env}"
MIRROR_NAME="local-buildcache"

log() { printf '\n=== [build] %s ===\n' "$*"; }

# Record the real exit status where the workflow can read it.
# script_submitter's UNSCHEDULED path (scheduler: false -> ssh_job) detaches this
# script with setsid and then polls `kill -0`, so it can see that the process
# ended but never why: a failed build otherwise reports a COMPLETED run. Verified
# on gce2 -- ucx failed to compile, build.sh aborted before the push and module
# steps, and the platform still recorded the run as completed.
BUILD_STATUS_FILE="${PWD}/BUILD_STATUS"
rm -f "$BUILD_STATUS_FILE"
trap 'rc=$?; printf "%s\n" "$rc" > "$BUILD_STATUS_FILE";
      [ "$rc" -eq 0 ] || echo "::error title=Error::build.sh exited $rc -- see the last === [build] === section above for the step that failed"' EXIT

# ---------------------------------------------------------------------------
# 0. Cancellation hook, written FIRST so a cancel at any later moment finds it.
#    script_submitter runs this on teardown; `spack install` leaves a lock in
#    the environment that would block the next run if it is killed mid-flight.
# ---------------------------------------------------------------------------
cat > cancel.sh <<EOF
#!/bin/bash
echo "[cancel] stopping spack build"
pkill -u "\$(id -u)" -f "spack-python|spack install" 2>/dev/null || true
rm -f "${ENV_DIR}/.lock" "${ENV_DIR}/spack.lock.lock" 2>/dev/null || true
exit 0
EOF
chmod +x cancel.sh

# On a worker the job was sized by the size_build job, and nproc is what the
# scheduler actually granted; compiling wider than that only oversubscribes it.
if [ "$BUILD_ON" = "compute" ] && [ "$JOBS" -gt "$(nproc)" ]; then
  echo "::notice::Parallel build jobs capped from ${JOBS} to the $(nproc) CPUs this job was given"
  JOBS="$(nproc)"
fi

# shellcheck disable=SC1091
# Search paths with duplicate entries corrupt vendor modulefiles. Spack writes
# the intel-oneapi-* modules by sourcing the vendor's vars.sh and recording what
# changed; with /home/<user>/pw on BOTH ends of PATH (inputs.sh prepends it to a
# PATH the platform already ends with) it recorded the ENTIRE build PATH as
# added -- `append-path PATH {/usr/bin}`, `{/bin}`, `{/home/pwuser/pw}` ... --
# so `module unload intel-oneapi-mpi` stripped /usr/bin and /bin from the
# user's shell (testbed 07-test-stack, 2026-11-16). De-duplicate first, keep
# the order, and remember what the build environment contained for the scrub
# after `module refresh` below.
dedup_path() { local IFS=: out="" seen=":" d; for d in $1; do [ -n "$d" ] || continue; case "$seen" in *":$d:"*) continue ;; esac; seen="$seen$d:"; out="${out:+$out:}$d"; done; printf '%s' "$out"; }
export PATH="$(dedup_path "$PATH")"
[ -n "${LD_LIBRARY_PATH:-}" ] && export LD_LIBRARY_PATH="$(dedup_path "$LD_LIBRARY_PATH")"
[ -n "${MANPATH:-}" ] && export MANPATH="$(dedup_path "$MANPATH")"
BUILD_ENV_PATH="$PATH"; BUILD_ENV_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"; BUILD_ENV_MANPATH="${MANPATH:-}"

. "$SPACK_ROOT/share/spack/setup-env.sh"
log "Spack $(spack --version) at $SPACK_ROOT, -j${JOBS}"
log "Build host: $(hostname) (${BUILD_ON} node, $(nproc) CPUs available, $(spack arch -t 2>/dev/null || echo '?'))"

# ---------------------------------------------------------------------------
# 0b. Site externals. Always the WORKER's view, whichever node compiles: the
#     binaries run on the workers, so an external that only the login node has
#     would link here and be missing there. Re-applied explicitly rather than
#     trusting the site scope, which holds whichever node -- or whichever run
#     sharing this Spack root -- discovered last. See find-externals.sh.
# ---------------------------------------------------------------------------
EXT_COMPUTE="${externals_compute:-}"
EXT_HEAD="${externals_head:-}"
if [ ! -f "$EXT_COMPUTE" ] && [ "$BUILD_ON" = "compute" ] && [ -n "$EXT_COMPUTE" ]; then
  # Full overrides skip the inspection job, but this IS a worker.
  log "No worker externals from inspection; discovering them on this build worker"
  bash "$APP_DIR/find-externals.sh" discover compute "$EXT_COMPUTE"
fi
if [ -f "$EXT_COMPUTE" ]; then
  log "Site externals: applying the compute node's ($EXT_COMPUTE)"
  bash "$APP_DIR/find-externals.sh" apply "$EXT_COMPUTE"
elif [ -f "$EXT_HEAD" ]; then
  echo "::warning::No compute-node externals for this run (inspection was skipped by the overrides); building against the LOGIN node's externals ($EXT_HEAD). If the images differ, binaries may not find these libraries on the workers." >&2
  bash "$APP_DIR/find-externals.sh" apply "$EXT_HEAD"
else
  echo "::error title=Error::No site externals file for this run (looked for ${EXT_COMPUTE:-<unset>} and ${EXT_HEAD:-<unset>})" >&2
  exit 1
fi

# The bootstrap compiler must be one THIS node has. controller.sh registered the
# login node's; on a worker with a different image that path may not exist here.
# A no-op when the compiler is already registered.
log "Registering this build host's system compilers"
spack compiler find --scope site

# ---------------------------------------------------------------------------
# 1. Load the resolved profile. Produced either by detect-fabric.sh on a worker
#    or synthesized by resolve-profile.sh from complete overrides.
# ---------------------------------------------------------------------------
[ -f "$FABRIC_ENV" ] || { echo "::error title=Error::No fabric profile at $FABRIC_ENV" >&2; exit 1; }
# shellcheck disable=SC1091
. "$FABRIC_ENV"
FRAG="$APP_DIR/templates/fabric-${FABRIC_PROFILE}.yaml"
[ -f "$FRAG" ] || { echo "::error title=Error::No fabric fragment $FRAG" >&2; exit 1; }
log "Fabric profile: $FABRIC_PROFILE (cloud=${CLOUD:-?}, detected on ${DETECT_HOST:-?})"

# Target: what detection saw on a COMPUTE node, reconciled against what this
# build host can actually emit. `packages: all: target:` is only a preference, so
# an unsupported target is silently dropped rather than rejected -- resolve-target.py
# makes that decision explicit and loud. See its docstring for the two directions.
WANTED_TARGET="${OVERRIDE_TARGET:-${BUILD_TARGET:-}}"
# Captured rather than `eval "$(...)"`: the resolver now exits non-zero when no
# target can serve both machines, and a command substitution inside eval swallows
# that -- eval would succeed on empty output and leave TARGET unset.
if ! TARGET_RESOLUTION="$(spack python "$APP_DIR/resolve-target.py" "$WANTED_TARGET")"; then
  echo "::error title=Error::cannot choose a build target for compute node '${WANTED_TARGET}' from this build host" >&2
  exit 1
fi
eval "$TARGET_RESOLUTION"
case "$TARGET_STATUS" in
  exact)    log "Target: $TARGET (matches compute node ${DETECT_HOST:-?})" ;;
  fallback) log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
  common)   log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
  host)     log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
esac

# --- GPU decision ----------------------------------------------------------
GPU_ACTIVE=0
EFFECTIVE_ARCH=""
if [ "$BUILD_GPU" = "true" ]; then
  if [ "${HAS_GPU:-0}" = "1" ] && [ -n "${GPU_ARCH:-}" ]; then
    GPU_ACTIVE=1; EFFECTIVE_ARCH="$GPU_ARCH"
    log "GPU path ENABLED: ${GPU_COUNT:-?}x ${GPU_NAME:-NVIDIA GPU}, cuda_arch=${EFFECTIVE_ARCH}, driver ${DRIVER_VERSION:-?}, driver CUDA ${CUDA_VERSION:-?}, toolkit ${CUDA_PREFIX:-<spack-built>} (nvcc ${NVCC_VERSION:-?})"
  else
    # Refuse rather than quietly build the CPU stack. Someone who ticked "build
    # the GPU path" and waited two hours for a stack with no CUDA in it has been
    # given the wrong answer slowly, which is worse than the right answer now.
    # The usual causes are an inspection job that landed on a GPU-less node, and
    # a node whose GPUs are hidden from the job because no GPU was requested.
    echo "::error title=Error::GPU build requested but the inspected node reported no usable GPU (HAS_GPU=${HAS_GPU:-0}, cuda_arch='${GPU_ARCH:-}', detected on ${DETECT_HOST:-?}). See the [detect] section above for what nvidia-smi said. Request a GPU for the inspection job (cluster.slurm.gpus), point it at a partition whose nodes have one, or turn off 'Build the GPU path'." >&2
    exit 1
  fi
fi

if [ "$GPU_ACTIVE" = "1" ] && [ -n "${CUDA_PREFIX:-}" ]; then
  # nvcc is the authority on the toolkit version; NVCC_VERSION from detection is
  # the same number read on the compute node, kept as the fallback.
  CUDA_VER="$("$CUDA_PREFIX/bin/nvcc" --version 2>/dev/null |
              grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
  CUDA_VER="${CUDA_VER:-${NVCC_VERSION:-}}"
  log "Registering external CUDA ${CUDA_VER:-<unknown version>} at $CUDA_PREFIX"
  [ -n "$CUDA_VER" ] || { echo "::error title=Error::cannot read a CUDA version from $CUDA_PREFIX/bin/nvcc" >&2; exit 1; }
  # The cluster's toolkit wins over the 'CUDA toolkit version' input -- but it
  # must work with the stack compiler. Spack refuses gcc 14 with CUDA <= 12.6
  # (build_systems/cuda.py), and that surfaces as an unreadable concretizer
  # error after gcc has been built. Say it now, in words.
  if [ "$(printf '%s\n12.8\n' "$CUDA_VER" | sort -V | head -1)" != "12.8" ]; then
    echo "::error title=Error::The CUDA toolkit on the compute nodes ($CUDA_PREFIX) is $CUDA_VER; the gcc 14 stack compiler needs CUDA 12.8 or newer. Upgrade it, or remove it from the compute nodes' path so Spack builds CUDA ${service_cuda_version:-12.9.1}." >&2
    exit 1
  fi
  [ -n "${service_cuda_version:-}" ] && [ "${service_cuda_version}" != "$CUDA_VER" ] && \
    echo "::notice::Using the cluster's CUDA $CUDA_VER from $CUDA_PREFIX; the 'CUDA toolkit version' input (${service_cuda_version}) only applies when Spack builds CUDA"

  # Written as a YAML file rather than passed to `spack config add` as a path
  # expression. That form cannot express this value: `config add` splits its
  # argument on ':', so the colons inside `spec:` and `prefix:` are read as more
  # path components and Spack rejects the result with
  #   {'[{spec': {' cuda@13.2, prefix': '/usr/local/cuda}]'}} is not of type 'array'
  # (gce2 run moral-ghost -- the first run ever to reach this line).
  cat > "${PWD}/cuda-external.yaml" <<YAML
packages:
  cuda:
    buildable: false
    externals:
    - spec: cuda@${CUDA_VER}
      prefix: ${CUDA_PREFIX}
YAML
  spack config --scope site add -f "${PWD}/cuda-external.yaml"
  spack config --scope site get packages | sed -n '/^  cuda:/,/^  [a-z]/p'
fi

# ---------------------------------------------------------------------------
# 2. Render spack.yaml from the template + the fabric fragment.
#    render-env.py runs under Spack's bundled Python so PyYAML is available
#    without adding a dependency to the cluster image. It is a real file because
#    `spack python -` does not read a script from stdin.
# ---------------------------------------------------------------------------
log "Rendering environment -> $ENV_DIR/spack.yaml"
mkdir -p "$ENV_DIR"
# A cluster is expected to hold SEVERAL stacks -- a CPU one and a GPU one, or
# stacks for different targets -- so the module tree is a form input rather than
# a fixed path under the Spack root. Spack keys the tree by spec architecture
# (<root>/<platform>-<os>-<target>), so differing targets already separate
# themselves; a separate root is for keeping stacks independent beyond that.
MODULE_ROOT="${service_module_root:-$SPACK_ROOT/share/spack/modules}"
mkdir -p "$MODULE_ROOT"

# GPU path inputs for render-env.py, by environment rather than more positional
# arguments. The CUDA pin applies only when Spack builds CUDA: a registered
# site external (CUDA_PREFIX, above) is non-buildable and would contradict it.
if [ "$GPU_ACTIVE" = "1" ]; then
  export SB_GPU_LIBS="${service_gpu_libraries:-cudnn nccl nvshmem cufftmp}"
  if [ -n "${CUDA_PREFIX:-}" ]; then export SB_CUDA_VERSION=""; else export SB_CUDA_VERSION="${service_cuda_version:-12.9.1}"; fi
fi
# Python environments are venvs on a Spack-built python@<version>, a root of
# this environment (render-env.py) so it is cached and gets a module.
if [ "${service_python_env:-false}" = "true" ]; then
  export SB_PYTHON_VERSION="${service_python_version:-3.11}"
fi
# Additional software: a file of Spack specs (one per line) and extra MPICH
# versions installed alongside the pinned one (render-env.py add_extra_specs).
export SB_EXTRA_SPECS_FILE="${extra_specs_file:-}"
export SB_MPICH_EXTRA_VERSIONS="${service_mpich_extra_versions:-}"
RENDER_OUT="$(spack python "$APP_DIR/render-env.py" \
      "$FRAG" "$APP_DIR/templates/spack.yaml.in" "$ENV_DIR/spack.yaml" \
      "$TARGET" "$GPU_ACTIVE" "$EFFECTIVE_ARCH" "$MODULE_ROOT")"
echo "$RENDER_OUT"
GCC_SPEC="$(printf '%s\n' "$RENDER_OUT" | sed -n 's/^GCC_SPEC=//p')"
[ -n "$GCC_SPEC" ] || { echo "::error title=Error::render-env.py did not report a stack compiler" >&2; exit 1; }
log "Stack compiler (from spack.yaml): $GCC_SPEC"

# MPICH's PMI. Every fabric fragment asks for pmi=pmi2, which suits clusters
# whose Slurm only offers pmi2. Where Slurm offers PMIx (detect-fabric.sh), use
# it: MPICH's own PMI2 client fails against current Slurm's pmi2 plugin
# ("pmijobid missing in fullinit command"), while PMIx lets plain srun launch
# MPICH exactly as it launches OpenMPI. Rewritten in the rendered file so the
# fragments stay the single source for every other MPICH setting.
if [ "${SLURM_MPI_PMIX:-0}" = "1" ] && grep -q 'pmi=pmi2' "$ENV_DIR/spack.yaml"; then
  sed -i 's/pmi=pmi2/pmi=pmix/g' "$ENV_DIR/spack.yaml"
  # ...and say so at run time. MPICH 4.2 picks its PMI when a program starts
  # (MPIR_CVAR_PMI_VERSION). Left unset it looks for the PMI-1 variables a
  # launcher would export, finds none under srun --mpi=pmix, and runs every
  # rank as a silent singleton ("rank 0 of 1" on each node; OSU then refuses
  # to run). Setting it to x selects PMIx, and every rank joins one job
  # (testbed 07-test-stack, 2026-11-17). Set in MPICH's modulefile, which the
  # gromacs and osu modules for MPICH autoload, so users get it by loading
  # the module. Module settings do not change any spec hash.
  spack -e "$ENV_DIR" config add 'modules:default:tcl:mpich:environment:set:MPIR_CVAR_PMI_VERSION:x'
  log "MPICH: pmi=pmix (this cluster's Slurm offers PMIx: ${SLURM_MPI_PLUGINS:-?}); its module sets MPIR_CVAR_PMI_VERSION=x; launch with srun (--mpi=pmix)"
else
  log "MPICH: pmi=pmi2 (no PMIx in this cluster's Slurm${SLURM_MPI_PLUGINS:+: $SLURM_MPI_PLUGINS})"
fi

# ---------------------------------------------------------------------------
# 3. Build the stack compiler with the system compiler, then register it.
#    This must happen OUTSIDE the environment: the environment requires this
#    compiler for every package, so it cannot also build it.
# ---------------------------------------------------------------------------
# Resolve the BUILT gcc by filtering to the install tree. `spack location -i
# "$GCC_SPEC"` cannot be used here: once the compiler is registered below there
# are two gcc@<version> entries -- the built package and the external entry that
# points at its prefix -- and location fails with "matches multiple packages".
gcc_built_prefix() {
  spack find --format '{prefix}' "$GCC_SPEC" 2>/dev/null | grep "^${SPACK_ROOT}/opt/" | head -1
}
gcc_built_hash() {
  spack find --format '{hash} {prefix}' "$GCC_SPEC" 2>/dev/null \
    | awk -v r="${SPACK_ROOT}/opt/" 'index($2, r) == 1 {print $1; exit}'
}

# The padding in templates/spack.yaml.in only reaches commands run IN the
# environment, and the gcc install, find and push below run outside it.
# Unpadded, gcc and its dependencies were cached with prefixes that cannot be
# relocated into a longer Spack root (CannotGrowString on aws run quality-colt).
# It goes in the site scope, not on the install command: the padded tree is a
# separate store with its own database, so every later command must see the
# same setting or gcc "matches no installed packages" right after installing
# (gce run cute-cockatoo). Keep the value equal to the template's.
spack config --scope site add config:install_tree:padded_length:128

if [ -z "$(gcc_built_prefix)" ]; then
  log "Installing stack compiler $GCC_SPEC (long; cached after the first run)"
  spack install --no-check-signature -j"$JOBS" "$GCC_SPEC"
else
  log "Stack compiler $GCC_SPEC already installed"
fi
# Pushed on every run, not only after installing: a run that installed gcc and
# then failed left it out of the cache for good, since the next run found it
# installed and skipped the push (gce runs cute-cockatoo -> ideal-flea). Entries
# already in the cache are skipped, so this is cheap when warm.
# --allow-missing: the push walks the whole DAG, and when gcc itself came from
# the build cache its build-only dependencies were never installed. Without the
# flag that prints a 27-line "Error: ... PackageNotInstalledError" block for a
# push that did exactly what it should.
# By hash, for the same reason as gcc_built_prefix(): once an earlier run has
# registered the external, "$GCC_SPEC" matches two packages and the push fails
# (gce run ample-trout).
GCC_HASH="$(gcc_built_hash)"
spack buildcache push --unsigned --update-index --private --allow-missing "$MIRROR_NAME" "/$GCC_HASH" || true

GCC_PREFIX="$(gcc_built_prefix)"
[ -n "$GCC_PREFIX" ] || { echo "::error title=Error::$GCC_SPEC not present under $SPACK_ROOT/opt after install" >&2; exit 1; }

# Register the built compiler as an external. REQUIRED, not cosmetic. Without it
# the environment fails to concretize with
#   Only external, or concrete, compilers are allowed for the c language
#   Cannot use gcc for the c virtual, but that is required
# even though `spack compiler list` already lists the built gcc.
#
# The governing rule is Spack's own solver, concretize.lp (v1.2.2, ~line 1930):
#
#   error(10, "Only external, or concrete, compilers are allowed for the {0} language", Language)
#     :- provider(ProviderNode, node(_, Language)), language(Language), build(ProviderNode).
#
# It names no package: it is scoped to the language virtuals (c, cxx, fortran,
# cuda-lang, hip-lang) and fires whenever a node PROVIDING one of them would have
# to be built in that solve. So it is not an Intel-specific quirk, though
# intel-oneapi-mpi is where it was observed here -- intel-oneapi-compilers has an
# explicit `depends_on gcc`, which forces a gcc node that must be built. For
# other packages an already-installed gcc can often be reused as "concrete" and
# the rule never fires, so which specs break without this registration depends on
# what reuse can supply. Maintainers have reported hitting it with OpenMPI too.
#
# "External" here does not mean "installed outside Spack" -- the prefix points
# back into Spack's own install tree. It means "a compiler Spack may use as a
# toolchain". Registering it adds a second gcc entry sharing that prefix, which
# is expected, and is why gcc_built_prefix() exists rather than
# `spack location -i` (which then fails with "matches multiple packages").
#
# Test for the external ENTRY (by prefix), not for the name in `spack compiler
# list`: the installed package already appears there, so a name check would
# always skip the registration and reintroduce the concretization failure.
if ! spack config --scope site get packages 2>/dev/null | grep -q "$GCC_PREFIX"; then
  log "Registering $GCC_SPEC as a site compiler"
  spack compiler find --scope site "$GCC_PREFIX"
fi
spack compiler list

# ---------------------------------------------------------------------------
# 4. Concretize. This is the gate: everything above is setup, and a clean DAG
#    here is what says the spec set is actually coherent.
# ---------------------------------------------------------------------------
log "Concretizing"
spack -e "$ENV_DIR" concretize -f
spack -e "$ENV_DIR" find -c || true

# Which of those specs the build cache can actually supply. Printed here, before
# the install, because it is the difference between "this run takes four minutes"
# and "this run takes two hours" -- and because a miss names the cached spec it
# collided with, which is what distinguishes a damaged cache from one built for a
# different fabric profile, image or microarchitecture.
log "Build cache coverage for this environment"
python3 "$APP_DIR/inspect-buildcache.py" "$BUILDCACHE_PATH" --lock "$ENV_DIR/spack.lock" || true

if [ "${service_concretize_only:-false}" = "true" ]; then
  log "concretize_only set; stopping before the install"
  exit 0
fi

# Every source this install will compile, downloaded into the shared source
# cache BEFORE anything builds. `spack install` only fetches what it reaches, so
# without this a login-node build that fails part way leaves a partial cache and
# a re-run on a worker would still need the internet. With it, that re-run
# downloads nothing. Placed after the concretize_only exit so a dry run stays
# fast. See prefetch-sources.py.
log "Fetching sources into the shared source cache"
spack -e "$ENV_DIR" python "$APP_DIR/prefetch-sources.py"

# ---------------------------------------------------------------------------
# 5. Install, then publish every result to the build cache. --private is
#    required: intel-oneapi-mpi is non-redistributable and is skipped silently
#    without it, which would leave a hole in the cache exactly where the
#    slowest-to-fetch package is.
# ---------------------------------------------------------------------------
log "Installing stack (this is the long part)"
INSTALL_LOG="${PWD}/spack-install.log"
if ! spack -e "$ENV_DIR" install --no-check-signature -j"$JOBS" 2>&1 | tee "$INSTALL_LOG"; then
  # Spack points at a per-package build log that lives on the node. Nobody
  # reading the workflow log has a shell there, so inline the tails: without
  # this, every compile failure costs a round trip to the cluster to learn which
  # header was missing.
  log "::error title=Error::spack install failed; tails of the failing build logs follow"
  # Spack names the failing logs in TWO formats and this has to catch both. A
  # single-package failure prints "See build log for details: <path>"; a
  # multi-package one prints a block of "<spec>/<hash>: <path>" under "The
  # following packages failed to install:". Matching only the first meant that on
  # gce2 run funky-pigeon -- gdrcopy and gromacs, the exact case this was written
  # for -- the loop found nothing and printed nothing at all.
  {
    grep -oE 'See build log for details: .*' "$INSTALL_LOG" | awk '{print $NF}'
    grep -oE '^[^ ]+@[^ ]+/[^ :]+: +/[^ ]+\.log$' "$INSTALL_LOG" | awk '{print $NF}'
  } | sort -u | while read -r build_log; do
    printf '\n----- last 120 lines of %s -----\n' "$build_log"
    tail -n 120 "$build_log" 2>/dev/null || \
      echo "(gone -- Spack removes the build stage when install exits, so this path is usually already deleted by the time we read it)"
  done

  # The reliable copy. Spack streams an excerpt of the failing package's build
  # output into its own stdout as it fails, marked with '>', and that is in this
  # file -- it is how ucx's "configure: error: RDMACM requested but required file
  # (rdma/rdma_cma.h) could not be found" was read on gce2 run hopeful-haddock,
  # while the stage log the loop above names had already been cleaned up. So
  # print this unconditionally rather than relying on those paths surviving.
  printf '\n----- last 150 lines of %s (Spack streamed output) -----\n' "$INSTALL_LOG"
  tail -n 150 "$INSTALL_LOG"
  exit 1
fi

# Did the cache do its job? The forecast above is a prediction; this is what
# happened, and the two disagreeing is itself worth seeing.
# Every number comes from this one install log, so they add up. Mixing in a
# `spack find` count does not: it reports the environment's view against a DAG
# the forecast counted whole, and two disagreeing totals in one log read as a bug
# in the run.
#
# "fetching from build cache" is an ATTEMPT, not a success -- Spack prints it for
# every spec and then follows with "no binary available" on a miss. Counting the
# attempts as hits, and source builds by "==> Installing", reported "4 from the
# build cache, 0 compiled" for a run that compiled four packages (gce2
# caring-warthog): Spack 1.2's progress output has no "==> Installing" line at
# all. Both numbers therefore come from the attempt/miss pair.
attempted="$(grep -c 'fetching from build cache' "$INSTALL_LOG" || true)"
compiled="$(grep -c 'no binary available' "$INSTALL_LOG" || true)"
extracted=$(( attempted - compiled ))

# A re-run installs nothing, and Spack then prints NOTHING at all -- not one
# line -- so the three counters above are all zero and the log reads as though
# the environment is empty (gce2 run welcome-deer, which passed). The total is a
# direct measurement of what is installed now; "already" is the remainder, so
# the four numbers always add up.
present="$(spack -e "$ENV_DIR" find --format '{hash}' 2>/dev/null | wc -l)"
already=$(( present - extracted - compiled ))
[ "$already" -lt 0 ] && already=0
log "Install complete: ${present} specs in the environment -- ${already} already installed, ${extracted} from the build cache, ${compiled} compiled from source"

log "Pushing to the build cache at $BUILDCACHE_PATH"
spack -e "$ENV_DIR" buildcache push --unsigned --update-index --private --allow-missing "$MIRROR_NAME" || true

# ---------------------------------------------------------------------------
# 6. Modules.
# ---------------------------------------------------------------------------
log "Refreshing modules"
# Externals have no modulefile, and `autoload: direct` would still list them as
# requirements -- one missing requirement aborts the entire `module load`, leaving
# the user silently on the system MPI. Exclude exactly what this site resolved as
# external.
MODULE_EXCLUDES="$(spack python "$APP_DIR/external-modules.py" "$ENV_DIR/spack.lock")"
log "Excluding from modules (externals): $MODULE_EXCLUDES"
spack -e "$ENV_DIR" config add "modules:default:tcl:exclude:[${MODULE_EXCLUDES}]"
# NOT --delete-tree: that deletes the WHOLE tree and regenerates only this
# environment's specs, so building a CPU stack silently removed the GPU stack's
# modules from the same root even though its installs were untouched (the GPU
# modules from run moral-silkworm were gone after run powerful-jaguar). Refresh
# without it and each stack's modules persist alongside the others.
# One flat folder (service_flat_modules, the default): <root>/<name>/<version>,
# so MODULEPATH is exactly the module root and the external gcc lands beside
# the stack instead of in a generic-target tree of its own. The price is one
# CPU target per root -- the same names from another target would overwrite
# these -- so the root records its target and refuses a different one.
FLAT_MODULES="${service_flat_modules:-false}"
if [ "$FLAT_MODULES" = "true" ]; then
  TARGET_STAMP="$MODULE_ROOT/.spack-builder-target"
  if [ -s "$TARGET_STAMP" ] && [ "$(cat "$TARGET_STAMP")" != "$TARGET" ]; then
    echo "::error title=Error::The module tree $MODULE_ROOT already holds a stack built for target '$(cat "$TARGET_STAMP")', and this one is for '$TARGET'. In one flat folder the second would overwrite the first. Use another 'Module tree root' for this target, or turn off 'One module folder'." >&2
    exit 1
  fi
  spack -e "$ENV_DIR" config add 'modules:default:arch_folder:false'
  printf '%s\n' "$TARGET" > "$TARGET_STAMP"
  log "Modules: one flat folder at $MODULE_ROOT (target $TARGET)"
fi
spack -e "$ENV_DIR" module tcl refresh -y

# Second line of defence against leaked search paths (see dedup_path above):
# no modulefile may add or remove a directory that merely came from THIS
# build's environment -- system dirs, the user's ~/pw -- unless it lies inside
# the Spack root. Unloading such a module would take /usr/bin out of the
# user's PATH, and a module written by one user's build must not carry that
# user's home into everyone else's shell. Logged per file, never silent.
scrub_leaked_paths() {
  local var="$1" value="$2" e esc files f n total=0
  local IFS=:
  for e in $value; do
    [ -n "$e" ] || continue
    case "$e" in "$SPACK_ROOT"/*) continue ;; esac
    esc="$(printf '%s' "$e" | sed 's/[][\\.*^$/+?(){}|]/\\&/g')"
    files="$(grep -rlE "^(append|prepend|remove)-path( -d [{]:[}])? ${var} [{]${esc}[}]$" "$MODULE_ROOT" 2>/dev/null || true)"
    [ -n "$files" ] || continue
    IFS=$'\n'
    for f in $files; do
      n="$(grep -cE "^(append|prepend|remove)-path( -d [{]:[}])? ${var} [{]${esc}[}]$" "$f")"
      sed -i -E "/^(append|prepend|remove)-path( -d [{]:[}])? ${var} [{]${esc}[}]$/d" "$f"
      echo "  removed ${n} leaked ${var} entr$( [ "$n" = 1 ] && echo y || echo ies) for ${e} from ${f#$MODULE_ROOT/}"
      total=$((total + n))
    done
    IFS=:
  done
  return 0
}
log "Scrubbing build-environment search paths that leaked into modulefiles"
leaked="$( { scrub_leaked_paths PATH "$BUILD_ENV_PATH"
             scrub_leaked_paths LD_LIBRARY_PATH "$BUILD_ENV_LD_LIBRARY_PATH"
             scrub_leaked_paths MANPATH "$BUILD_ENV_MANPATH"; } )"
if [ -n "$leaked" ]; then
  printf '%s\n' "$leaked"
  echo "::warning::Removed $(printf '%s\n' "$leaked" | wc -l) leaked search-path lines from generated modulefiles (vendor env scripts, usually intel-oneapi-*); see the list above"
else
  echo "  none found"
fi

# Re-runs install new versions beside the old ones; the newest version of each
# package becomes its module default (.modulerc), the older ones stay loadable
# by full name. See set-module-defaults.py.
log "Module defaults: newest version of each package"
spack python "$APP_DIR/set-module-defaults.py" "$MODULE_ROOT"

# `spack arch` reports the LOGIN node, but the modules are written under the
# spec's architecture -- and on a cross-architecture cluster, which is the case
# this workflow exists for, those differ. Run moral-silkworm built x86_64_v3 and
# printed a skylake_avx512 MODULEPATH that held none of its modules.
MODROOT="$MODULE_ROOT/$(spack arch -p)-$(spack arch -o)-${TARGET}"
[ "$FLAT_MODULES" = "true" ] && MODROOT="$MODULE_ROOT"

# The compiler is external with a GENERIC target, so its modulefile lands in a
# DIFFERENT tree from everything built with it (linux-rocky9-x86_64 next to
# linux-rocky9-skylake_avx512) and a MODULEPATH holding only $MODROOT offers no
# compiler at all -- the stack can then be run but nothing new can be built
# against it. Ask Spack where it wrote the file instead of reconstructing the
# generic target name, which is not derivable from $TARGET.
# `|| true`: under `set -e` a failed lookup here would abort the run at its very
# last step, after a fully successful build and push.
GCC_MODFILE="$(spack -e "$ENV_DIR" module tcl find --full-path gcc 2>/dev/null | head -1 || true)"
if [ -n "$GCC_MODFILE" ] && [ -f "$GCC_MODFILE" ]; then
    GCC_MODROOT="$(dirname "$(dirname "$GCC_MODFILE")")"
else
    GCC_MODROOT=""
fi

if [ "$FLAT_MODULES" = "true" ]; then
    MODULEPATH_VALUE="$MODROOT"
    if [ -n "$GCC_MODROOT" ]; then
        GCC_LOAD_LINE="    module load gcc          # gcc/g++/gfortran + CC/CXX/FC, to COMPILE"
        GCC_NOTE="One folder holds the whole stack, compiler included."
    else
        GCC_LOAD_LINE="    # no compiler module was generated -- 'spack load gcc' for gcc/g++/gfortran"
        GCC_NOTE="No compiler modulefile was found under $MODULE_ROOT."
    fi
elif [ -n "$GCC_MODROOT" ] && [ "$GCC_MODROOT" != "$MODROOT" ]; then
    MODULEPATH_VALUE="$MODROOT:$GCC_MODROOT"
    GCC_LOAD_LINE="    module load gcc          # gcc/g++/gfortran + CC/CXX/FC, to COMPILE"
    GCC_NOTE="BOTH directories are needed. $(basename "$MODROOT") holds the stack;
$(basename "$GCC_MODROOT") holds the compiler, which Spack files under a generic
target because it is registered as an external. With only the first, openmpi
loads and RUNS but there is no gcc/g++/gfortran to build anything new against."
else
    MODULEPATH_VALUE="$MODROOT"
    GCC_LOAD_LINE="    # no compiler module was generated -- 'spack load gcc' for gcc/g++/gfortran"
    GCC_NOTE="No compiler modulefile was found under $MODULE_ROOT."
fi

if [ "$FLAT_MODULES" = "true" ]; then
    MODULEPATH_NOTE="
With 'Add the modules to every user's MODULEPATH at login' on, new login
shells get this automatically (the login_hook job reports where it installed)."
else
    MODULEPATH_NOTE="
MODULEPATH must name the module tree(s) above exactly, never the parent

    $MODULE_ROOT

The autoload lines inside every modulefile are bare names resolved against a
MODULEPATH entry, so a parent-level entry makes every load fail with
\"ERROR: Unable to locate a modulefile for 'gcc-runtime/14.2.0-none-none'\"."
fi

# The endpoint job prints this same MODULEPATH on its page. It runs in its own
# directory, after this script has exited, with no Spack environment set up --
# so the value is handed over through the shared run dir instead of being
# recomputed there from `spack arch` and a target it does not have.
if [ -n "${modulepath_env:-}" ]; then
    printf '%s\n' "$MODULEPATH_VALUE" > "$modulepath_env"
fi

# Python environments and the Conda/Mamba module, after the stack and its module
# tree exist. Each venv is built on the Spack python and gets a module in the
# same tree; see build-python-envs.sh.
if [ "${service_python_env:-false}" = "true" ] || [ "${service_miniforge:-false}" = "true" ]; then
  log "Python environments / Conda"
  if ! SPACK_ROOT="$SPACK_ROOT" ENV_DIR="$ENV_DIR" MODULE_DIR="${MODULEPATH_VALUE%%:*}" \
       bash "$APP_DIR/build-python-envs.sh"; then
    echo "::error title=Error::One or more Python environments (or Miniforge) failed -- see the [python] sections above. The Spack stack itself is installed and its modules are in place." >&2
    exit 1
  fi
fi

cat <<EOF

=== DONE ===
Stack built for target: $TARGET  (fabric=$FABRIC_PROFILE, cloud=${CLOUD:-?})
GPU path: $( [ "$GPU_ACTIVE" = "1" ] && echo "ENABLED (cuda_arch=${EFFECTIVE_ARCH})" || echo "disabled" )

    export MODULEPATH=$MODULEPATH_VALUE:\$MODULEPATH
$GCC_LOAD_LINE
    module load openmpi      # or mpich / intel-oneapi-mpi
    module load gromacs

$GCC_NOTE
$MODULEPATH_NOTE
EOF
