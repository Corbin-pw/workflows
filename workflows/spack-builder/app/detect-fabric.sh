#!/usr/bin/env bash
# detect-fabric.sh
# Detects (1) the cloud provider and (2) whether RDMA-class fabric hardware is
# present, then prints a fabric profile keyword and exports helper vars.
#
# Output: writes KEY=VALUE lines to $1 (default: ./fabric.env), sourceable by build.sh.
#   CLOUD           = aws|azure|gcp|oracle|unknown
#   FABRIC_PROFILE  = aws|azure|gcp|oracle|generic   (which fabric fragment to use)
#   HAS_EFA         = 0|1
#   HAS_VERBS       = 0|1   (InfiniBand / RoCE verbs device present)
#   EFA_PREFIX      = path to vendor libfabric (AWS), if found
#   HAS_GPU         = 0|1   (NVIDIA GPU present)
#   GPU_ARCH        = detected CUDA compute capability as spack cuda_arch (e.g. 80), or empty
#   CUDA_PREFIX     = path to an existing CUDA toolkit, if found (else empty -> Spack builds it)
#   BUILD_TARGET    = spack microarch target of THIS node (e.g. skylake_avx512)
#   BUILD_ARCH      = full spack arch triple of THIS node
#   DETECT_HOST     = hostname this ran on
#   DETECT_NPROC    = CPUs this inspection job was given (nproc)
#   DETECT_CPUS_LOGICAL / DETECT_CPUS_PHYSICAL / DETECT_CPUS_SLURM
#                   = the whole node's threads, physical cores and Slurm CPUTot
#                     (cpu-counts.sh); they size a build job on this node type
#
# The hardware probe is authoritative. Cloud identity only breaks ties on which
# vendor libfabric to prefer. An instance on AWS with no EFA -> generic profile.
# GPU detection is reported but only *acted on* when the caller sets BUILD_GPU=1.

set -euo pipefail
# script_submitter runs a script assembled as `inputs.sh + this file`, so there
# are no positional arguments in the workflow path -- fall back to the
# fabric_env variable that inputs.sh exports.
OUT="${1:-${fabric_env:-./fabric.env}}"

# Written first so a cancel at any later point finds it. Detection touches
# nothing that needs undoing; the file exists because script_submitter warns
# when its cleanup script is missing.
cat > cancel.sh <<'CANCEL'
#!/bin/bash
echo "[cancel] fabric detection stopped; nothing to clean up"
exit 0
CANCEL
chmod +x cancel.sh

log() { printf '[detect] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Cloud identity via metadata endpoints (short timeouts; all are link-local).
# ---------------------------------------------------------------------------
detect_cloud() {
  # Every probe uses `curl -sf`. Without --fail, curl exits 0 on an HTTP error
  # response, and 169.254.169.254 is the link-local metadata address on AWS,
  # Azure AND Oracle -- so on GCP the AWS IMDSv2 probe received a 1599-byte HTML
  # error page, `[ -n "$t" ]` passed, the instance-id GET "succeeded" with exit 0,
  # and a GCE node reported CLOUD=aws. That in turn made the gcp fabric profile
  # unreachable on GCP, since it is only selected when CLOUD=gcp.
  #
  # Order matters too: GCP is checked first because it is the only provider with
  # a distinctive hostname rather than the shared link-local address.
  local t id

  # GCP: distinct hostname, and the Metadata-Flavor header is mandatory.
  if curl -sf --max-time 2 -H "Metadata-Flavor: Google" \
       "http://metadata.google.internal/computeMetadata/v1/instance/id" >/dev/null 2>&1; then
    echo gcp; return
  fi

  # Azure IMDS: requires Metadata:true and a distinct path.
  if curl -sf --max-time 2 -H "Metadata:true" \
       "http://169.254.169.254/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1; then
    echo azure; return
  fi

  # Oracle OCI instance metadata (v2).
  if curl -sf --max-time 2 -H "Authorization: Bearer Oracle" \
       "http://169.254.169.254/opc/v2/instance/" >/dev/null 2>&1; then
    echo oracle; return
  fi

  # AWS IMDSv2 last, and only trusted when the instance id actually looks like
  # one -- a 200 from some other cloud's metadata service must not count.
  if t=$(curl -sf --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) && [ -n "$t" ]; then
    if id=$(curl -sf --max-time 2 -H "X-aws-ec2-metadata-token: $t" \
         "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null) \
       && printf '%s' "$id" | grep -qE '^i-[0-9a-f]+$'; then
      echo aws; return
    fi
  fi

  echo unknown
}

# ---------------------------------------------------------------------------
# 2. Hardware probes — independent of cloud identity.
# ---------------------------------------------------------------------------
probe_efa() {
  # EFA shows up as an ib_device via the efa kernel driver, and the installer
  # drops libfabric under /opt/amazon/efa.
  if [ -d /sys/class/infiniband ] && ls /sys/class/infiniband/ 2>/dev/null | grep -qi '^rdmap\|efa'; then
    return 0
  fi
  # fi_info from the vendor libfabric is the definitive check when present.
  if [ -x /opt/amazon/efa/bin/fi_info ] && \
     /opt/amazon/efa/bin/fi_info -p efa >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

probe_verbs() {
  # A verbs-capable fabric (Mellanox IB/RoCE on Azure HB/ND, Oracle cluster
  # networks, GCP RoCE) exposes /sys/class/infiniband/<dev>/ports/<n>. A DEVICE
  # is not enough: ordinary Azure VMs with Accelerated Networking expose their
  # SR-IOV Mellanox NIC (mlx5, link_layer Ethernet) there too, with no RDMA
  # fabric behind it. Counting that device sent an NC-series T4 VM down the
  # azure UCX-over-verbs profile (testbed run tb-spack-builder, 2026-11-13).
  # So every port is logged, only ACTIVE ports count, and on Azure only
  # InfiniBand ports do -- Azure's RDMA SKUs (HB/HC/HX/ND) are InfiniBand.
  # The old `ibv_devinfo` fallback is gone: it reads the same devices from the
  # same sysfs tree and would have counted the NIC all over again.
  local d p name state ll found=1
  [ -d /sys/class/infiniband ] || return 1
  for d in /sys/class/infiniband/*; do
    [ -e "$d" ] || continue
    name="$(basename "$d")"
    # Exclude the pure-EFA case (efa has no traditional verbs QP semantics for UCX).
    case "$name" in efa*) continue ;; esac
    for p in "$d"/ports/*; do
      [ -e "$p" ] || continue
      state="$(cat "$p/state" 2>/dev/null || true)"
      ll="$(cat "$p/link_layer" 2>/dev/null || true)"
      log "rdma device ${name} port $(basename "$p"): link_layer=${ll:-?} state=${state:-?}"
      case "$state" in *ACTIVE*) ;; *) log "  ignored: port not ACTIVE"; continue ;; esac
      if [ "${CLOUD:-unknown}" = "azure" ] && [ "$ll" != "InfiniBand" ]; then
        log "  ignored: an Ethernet mlx5 port on Azure is Accelerated Networking (SR-IOV NIC), not an RDMA fabric"
        continue
      fi
      found=0
    done
  done
  return $found
}

# GPU detection. Returns 0 if an NVIDIA GPU is present. Sets globals GPU_ARCH,
# CUDA_PREFIX as side effects.
GPU_ARCH=""; CUDA_PREFIX=""; GPU_NAME=""; GPU_COUNT=0
DRIVER_VERSION=""; CUDA_VERSION=""; NVCC_VERSION=""
probe_gpu() {
  local found=1
  # PCI enumeration works even without the driver loaded.
  if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi 'nvidia'; then
    found=0
  fi
  # nvidia-smi is authoritative when the driver is up, and gives the arch directly.
  # It must be checked by EXIT STATUS, not by whether it printed something: with
  # the toolkit installed but no GPU (or no driver) it exits 9 and writes its
  # complaint to STDOUT, so `2>/dev/null` does not hide it. Capturing that blindly
  # set HAS_GPU=1 and made the error text the cuda_arch on a GPU-less node.
  #
  # Every failure below is LOGGED rather than swallowed. A silent failure here is
  # indistinguishable in the log from a node with no GPU, and the consequence is
  # severe and quiet: build.sh needs HAS_GPU=1 *and* a non-empty GPU_ARCH, so an
  # unexplained empty arch turns a requested GPU build into a CPU-only one after
  # hours of compiling. Seen on gce2 run thorough-oryx: lspci found the device,
  # nvidia-smi reported nothing, and the log could not say why.
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi not on PATH; cannot read the compute capability"
  else
    local smi_out smi_rc
    # Every GPU, not just the first: the count and the models are what tell a
    # reader whether the job actually got the hardware the node has. A node with
    # 2 H100s that reports one line -- or none -- is the interesting case, and
    # the old probe could not express the difference.
    smi_out=$(nvidia-smi --query-gpu=index,name,compute_cap,driver_version,memory.total \
                         --format=csv,noheader 2>&1)
    smi_rc=$?
    if [ $smi_rc -ne 0 ]; then
      log "nvidia-smi exited ${smi_rc}: ${smi_out}"
    else
      GPU_COUNT=$(printf '%s\n' "$smi_out" | grep -c '[^[:space:]]' || true)
      log "nvidia-smi reports ${GPU_COUNT} GPU(s) visible to this job:"
      printf '%s\n' "$smi_out" | while IFS= read -r line; do [ -n "$line" ] && log "  ${line}"; done
      GPU_NAME="$(printf '%s' "$smi_out" | head -n1 | cut -d, -f2 | xargs)"
      DRIVER_VERSION="$(printf '%s' "$smi_out" | head -n1 | cut -d, -f4 | xargs)"
      local cc caps
      # compute_cap is like "9.0"; strip the dot -> spack cuda_arch "90".
      cc="$(printf '%s' "$smi_out" | head -n1 | cut -d, -f3 | tr -d ' ')"
      # A mixed-GPU node cannot be served by one cuda_arch; say so rather than
      # silently building for whichever card happens to be index 0.
      caps="$(printf '%s\n' "$smi_out" | cut -d, -f3 | tr -d ' ' | sort -u | tr '\n' ' ')"
      if [ "$(printf '%s' "$caps" | wc -w)" -gt 1 ]; then
        log "WARNING: this node has mixed compute capabilities (${caps}); building for ${cc}"
      fi
      if [[ "$cc" =~ ^[0-9]+\.[0-9]+$ ]]; then
        GPU_ARCH="${cc//./}"
        found=0
        log "selected: ${GPU_COUNT}x ${GPU_NAME}, compute capability ${cc} -> cuda_arch=${GPU_ARCH}, driver ${DRIVER_VERSION}"
      else
        log "nvidia-smi returned no usable compute capability (got '${cc}' from: ${smi_out})"
      fi
    fi
    # The driver's CUDA runtime version, which is what decides whether a given
    # GROMACS or OpenMPI release can be built against this node at all.
    CUDA_VERSION="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -n1)"
    [ -n "$CUDA_VERSION" ] && log "driver CUDA runtime: ${CUDA_VERSION}"
  fi
  # Locate an existing CUDA toolkit so we can register it external (faster builds).
  for p in /usr/local/cuda "${CUDA_HOME:-}" /opt/cuda; do
    [ -n "$p" ] || continue
    if [ -x "$p/bin/nvcc" ]; then CUDA_PREFIX="$(cd "$p" && pwd)"; break; fi
  done
  if [ -n "$CUDA_PREFIX" ]; then
    NVCC_VERSION="$("$CUDA_PREFIX/bin/nvcc" --version 2>/dev/null |
                    sed -n 's/.*release \([0-9.]*\).*/\1/p' | head -n1)"
    log "CUDA toolkit at ${CUDA_PREFIX} (nvcc ${NVCC_VERSION:-unknown})"
  else
    log "no CUDA toolkit found; Spack would have to build one"
  fi
  return $found
}

# ---------------------------------------------------------------------------
# 2b. Microarchitecture of THIS node.
# The build runs on the login node by default, which is frequently a different
# instance type from the compute nodes. `spack arch -t` there would bake the
# login node's ISA into every package -- either leaving compute performance on
# the table or emitting instructions that SIGILL on the worker. So the whole
# reason this script is submitted to a worker is to carry that value back.
# ---------------------------------------------------------------------------
probe_target() {
  local root="${service_install_prefix:-}"
  if [ -z "$root" ] || [ ! -f "$root/share/spack/setup-env.sh" ]; then
    log "WARNING: no Spack at '${root:-<unset>}'; cannot report a build target"
    return 0
  fi
  # shellcheck disable=SC1091
  . "$root/share/spack/setup-env.sh"
  BUILD_TARGET="$(spack arch -t 2>/dev/null || echo "")"
  BUILD_ARCH="$(spack arch 2>/dev/null || echo "")"
  log "build target: ${BUILD_TARGET:-<unknown>} (arch=${BUILD_ARCH:-<unknown>})"
}

# ---------------------------------------------------------------------------
# 3. Decide the profile.
# ---------------------------------------------------------------------------
BUILD_TARGET=""; BUILD_ARCH=""
probe_target
eval "$(bash "${app_dir}/cpu-counts.sh")"
log "detected on host $(hostname): ${CPUS_PHYSICAL} physical cores, ${CPUS_LOGICAL} logical CPUs, Slurm CPUTot ${CPUS_SLURM:-n/a}, $(nproc) given to this job"
CLOUD=$(detect_cloud)
log "cloud identity: $CLOUD"

HAS_EFA=0; HAS_VERBS=0; EFA_PREFIX=""; HAS_GPU=0
if probe_efa;   then HAS_EFA=1;   EFA_PREFIX="/opt/amazon/efa"; log "EFA fabric detected"; fi
if probe_verbs; then HAS_VERBS=1; log "verbs (IB/RoCE) fabric detected"; fi
if probe_gpu;   then HAS_GPU=1;   log "NVIDIA GPU detected (arch=${GPU_ARCH:-unknown}, cuda=${CUDA_PREFIX:-none})"; fi

# Profile selection: hardware first, cloud identity as the tie-breaker.
FABRIC_PROFILE="generic"
if   [ "$HAS_EFA" -eq 1 ]; then
  FABRIC_PROFILE="aws"                     # OFI/EFA path regardless of reported cloud
elif [ "$HAS_VERBS" -eq 1 ]; then
  case "$CLOUD" in
    azure)  FABRIC_PROFILE="azure"  ;;     # UCX + verbs, Mellanox tuned
    oracle) FABRIC_PROFILE="oracle" ;;     # UCX + verbs on cluster network
    gcp)    FABRIC_PROFILE="gcp"    ;;     # verbs/RoCE path
    *)      FABRIC_PROFILE="azure"  ;;     # generic verbs -> UCX profile
  esac
elif [ "$CLOUD" = "gcp" ]; then
  # GCP H3/C3 Titanium exposes OFI without a classic verbs device; prefer OFI.
  FABRIC_PROFILE="gcp"
fi

log "selected fabric profile: $FABRIC_PROFILE"

# Which MPI plugins this cluster's Slurm offers. MPICH's own PMI2 client does
# not interoperate with current Slurm's pmi2 plugin: on Slurm 25.11 every rank
# died in MPI_Init with "error: pmijobid missing in fullinit command" (testbed
# 07-test-stack, 2026-11-16) -- the server requires a key MPICH 4.2 does not
# send. Where Slurm has PMIx, build.sh builds MPICH with pmi=pmix instead, the
# same PMIx path OpenMPI already launches through. Read here, on the worker,
# because the build runs against what the compute nodes offer.
SLURM_MPI_PMIX=0; SLURM_MPI_PLUGINS=""
if command -v srun >/dev/null 2>&1; then
  SLURM_MPI_PLUGINS="$(srun --mpi=list 2>&1 | awk '/^(srun: |[ \t]+)[a-z_0-9]+[ \t]*$/ {printf "%s ", $NF} /versions available/ {sub(/.*available: */, ""); printf "(%s) ", $0}' | sed 's/ *$//')"
  printf '%s\n' "$SLURM_MPI_PLUGINS" | grep -qw pmix && SLURM_MPI_PMIX=1
fi
log "Slurm MPI plugins: ${SLURM_MPI_PLUGINS:-<srun not found>} -> PMIx $( [ "$SLURM_MPI_PMIX" = 1 ] && echo available || echo not available)"

# Every value is QUOTED. This file is sourced, and until GPU_NAME arrived every
# value it carried was a single token -- profiles, 0/1 flags, paths, targets --
# so nothing needed quoting and nothing revealed that. The first multi-word value
# turned line 8 into `GPU_NAME=NVIDIA` followed by the command `H100`, and
# sourcing it aborted build.sh with status 127 before it did anything at all
# (gce2 run loving-firefly). Quote on write, not on read: a consumer cannot undo
# this, and the next field with a space would repeat it.
cat > "$OUT" <<EOF
CLOUD="$CLOUD"
FABRIC_PROFILE="$FABRIC_PROFILE"
HAS_EFA="$HAS_EFA"
HAS_VERBS="$HAS_VERBS"
EFA_PREFIX="$EFA_PREFIX"
HAS_GPU="$HAS_GPU"
GPU_ARCH="$GPU_ARCH"
GPU_NAME="$GPU_NAME"
GPU_COUNT="$GPU_COUNT"
DRIVER_VERSION="$DRIVER_VERSION"
CUDA_VERSION="$CUDA_VERSION"
NVCC_VERSION="$NVCC_VERSION"
CUDA_PREFIX="$CUDA_PREFIX"
BUILD_TARGET="$BUILD_TARGET"
BUILD_ARCH="$BUILD_ARCH"
DETECT_HOST="$(hostname)"
DETECT_NPROC="$(nproc)"
DETECT_CPUS_LOGICAL="$CPUS_LOGICAL"
DETECT_CPUS_PHYSICAL="$CPUS_PHYSICAL"
DETECT_CPUS_SLURM="$CPUS_SLURM"
SLURM_MPI_PMIX="$SLURM_MPI_PMIX"
SLURM_MPI_PLUGINS="$SLURM_MPI_PLUGINS"
EOF
log "wrote $OUT"

# Header inventory of THIS (compute) node, written beside fabric.env so the
# head-node step can diff the two. Externals are detected from libraries but
# COMPILED against, so which -devel packages an image carries decides whether
# ucx/libfabric/slurm survive as externals or get rebuilt -- and that was
# previously invisible in the log. CUDA_PREFIX is exported because the probe
# searches it for cuda.h.
CUDA_PREFIX="${CUDA_PREFIX}" bash "${app_dir}/probe-headers.sh" \
  "$(dirname "$OUT")/headers.compute.env" compute || \
  log "WARNING: header probe failed; continuing (detection is not gated on it)"

# Site externals as THIS node sees them. The build concretizes against this
# file wherever it compiles, because the binaries run here, not on the login
# node (find-externals.sh). Fatal on failure: without it the build would fall
# back to the login node's view, which is the thing this exists to avoid.
bash "${app_dir}/find-externals.sh" discover compute \
  "${externals_compute:-$(dirname "$OUT")/externals.compute.yaml}"

# To stdout, not through log(): this is the one artifact the build consumes, and
# reading it back out of the log is how a wrong fabric profile or target gets
# diagnosed without a shell on the compute node.
printf '\n=== [detect] resolved profile ===\n'
cat "$OUT"
