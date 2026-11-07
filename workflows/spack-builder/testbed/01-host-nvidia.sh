#!/usr/bin/env bash
# 01-host-nvidia.sh -- NVIDIA driver on the HOST only.
# Run:  sudo ./01-host-nvidia.sh      (reboot when told, then run it again to verify)
#
# Design: the driver lives on the host and LXD injects its userspace (nvidia-smi,
# libcuda, libnvidia-ml) into each node with nvidia.runtime=true. The nodes never
# install a driver -- same as a real cluster, where the driver is node-level and
# the CUDA *toolkit* comes from Spack/modules. CUDA 12.4+ needs driver >= 550;
# CUDA 12.8/12.9 needs >= 570; CUDA 13.x needs >= 580.
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
need_root
tb_start_log

MIN_MAJOR=570
current_major() { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1; }

say "Current state"
if nvidia-smi >/dev/null 2>&1; then
  maj="$(current_major)"
  nvidia-smi --query-gpu=index,pci.bus_id,name,compute_cap,driver_version --format=csv
  if [ "${maj:-0}" -ge "$MIN_MAJOR" ]; then
    ok "driver ${maj}.x already loaded (>= ${MIN_MAJOR}); skipping install"
    SKIP_INSTALL=1
  else
    warn "driver ${maj}.x is older than ${MIN_MAJOR}; it will be replaced"
    SKIP_INSTALL=0
  fi
else
  echo "  no working driver ($(nvidia-smi 2>&1 | head -1))"
  SKIP_INSTALL=0
fi

if [ "$SKIP_INSTALL" = 0 ]; then
  say "Installing driver"
  apt-get update
  apt-get install -y ubuntu-drivers-common pciutils mokutil
  mokutil --sb-state 2>/dev/null | grep -qi enabled && \
    warn "Secure Boot is ENABLED: ubuntu-drivers installs Canonical-SIGNED prebuilt modules, which load fine. Avoid DKMS builds."

  # Blacklist nouveau so it cannot grab either card first.
  cat > /etc/modprobe.d/blacklist-nouveau.conf <<'NV'
blacklist nouveau
options nouveau modeset=0
NV

  BR="${NVIDIA_DRIVER_BRANCH}"
  if [ -z "$BR" ]; then
    BR="$(ubuntu-drivers list --gpgpu 2>/dev/null | grep -oE 'nvidia-driver-[0-9]+-server' | grep -oE '[0-9]+' | sort -n | tail -1)"
  fi
  [ -n "$BR" ] || die "could not determine a driver branch; set NVIDIA_DRIVER_BRANCH in config.env (e.g. 580)"
  [ "$BR" -ge "$MIN_MAJOR" ] || warn "branch $BR < $MIN_MAJOR: CUDA 12.8+ toolkits will refuse to run"
  echo "  branch: ${BR}-server (open kernel modules -- supported on Turing (T4) and newer)"

  # --gpgpu = compute stack, signed prebuilt kernel modules, no Xorg bits.
  if ! ubuntu-drivers install --gpgpu "nvidia:${BR}-server-open"; then
    warn "open variant not offered; falling back to the proprietary server modules"
    ubuntu-drivers install --gpgpu "nvidia:${BR}-server"
  fi
  # --gpgpu does not include nvidia-smi / NVML; LXD's nvidia.runtime needs both.
  apt-get install -y "nvidia-utils-${BR}-server" "libnvidia-compute-${BR}-server" || true

  # If this box runs a desktop, it also needs the X driver.
  if systemctl is-active --quiet display-manager 2>/dev/null; then
    warn "a display manager is running; installing the full driver for the desktop as well"
    apt-get install -y "nvidia-driver-${BR}-server-open" || apt-get install -y "nvidia-driver-${BR}-server"
  fi
fi

say "Protecting the driver from silent upgrades"
# unattended-upgrades swapping the userspace under a loaded module gives
# "Driver/library version mismatch" on every GPU job (seen on a customer GPU server).
pkgs="$(dpkg -l | awk '/^ii/ && ($2 ~ /nvidia/ || $2 ~ /^linux-modules-nvidia/) {print $2}')"
[ -n "$pkgs" ] && apt-mark hold $pkgs >/dev/null && ok "held: $(echo $pkgs | wc -w) packages"
cat > /etc/apt/apt.conf.d/51-testbed-no-nvidia-autoupgrade <<'UU'
Unattended-Upgrade::Package-Blacklist { "nvidia-"; "libnvidia-"; "linux-modules-nvidia-"; "linux-objects-nvidia-"; "linux-signatures-nvidia-"; };
UU
ok "unattended-upgrades blacklist written"

if nvidia-smi >/dev/null 2>&1 && [ "${SKIP_INSTALL}" = 1 ]; then
  say "Persistence mode + verification"
  systemctl enable --now nvidia-persistenced 2>/dev/null || nvidia-smi -pm 1 || true
  nvidia-smi --query-gpu=index,pci.bus_id,name,memory.total,compute_cap,driver_version,persistence_mode,mig.mode.current --format=csv
  nvidia-smi | sed -n '3p'
  ok "host driver ready -- next: sudo ./02-host-lxd.sh"
else
  say "REBOOT REQUIRED"
  echo "  sudo reboot     then run: sudo ./01-host-nvidia.sh   (it verifies and moves on)"
fi
echo "Log saved: $TB_LOG"
