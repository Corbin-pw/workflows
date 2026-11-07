#!/usr/bin/env bash
# 00-preflight.sh -- READ-ONLY host survey. Changes nothing.
# Run:  sudo ./00-preflight.sh
# Produces a report (also saved under logs/) used to fill in config.env and to
# document the testbed host. Paste the summary at the end back to Claude.
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
tb_start_log
set +e   # survey script: keep going past failed probes and report them

say "Host"
. /etc/os-release
echo "  OS:      $PRETTY_NAME"; echo "  Kernel:  $(uname -r)"; echo "  Host:    $(hostname -f 2>/dev/null || hostname)"
case "${VERSION_ID}" in 22.04|24.04) ok "Ubuntu ${VERSION_ID}" ;; *) warn "untested host OS ${VERSION_ID} (22.04 or 24.04 expected)" ;; esac
# Azure: VM size from the instance metadata service (no-op elsewhere).
vmsize="$(curl -sf --noproxy '*' -m 3 -H Metadata:true 'http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text' 2>/dev/null)"
[ -n "$vmsize" ] && echo "  Azure VM size: $vmsize  (region: $(curl -sf --noproxy '*' -m 3 -H Metadata:true 'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text'))"
echo "  CPU:     $(lscpu | sed -n 's/^Model name: *//p')"
echo "  Threads: $(nproc)  Sockets: $(lscpu | sed -n 's/^Socket(s): *//p')  Cores/socket: $(lscpu | sed -n 's/^Core(s) per socket: *//p')"
echo "  Flags:   avx2=$(grep -qw avx2 /proc/cpuinfo && echo y || echo n) avx512f=$(grep -qw avx512f /proc/cpuinfo && echo y || echo n)"
echo "  Memory:  $(free -g | awk '/Mem:/{print $2" GiB total, "$7" GiB available"}')"
echo "  cgroup:  $(stat -fc %T /sys/fs/cgroup)  (cgroup2fs = v2)"
echo "  Virt:    $(systemd-detect-virt 2>/dev/null || echo none)"

say "Disk (testbed data goes to ${HOST_BASE}; Spack + ML stack wants >=300 GB)"
df -hT / /srv /var/snap 2>/dev/null | awk 'NR==1 || !seen[$0]++'
fs="$(df --output=fstype "$(dirname "$HOST_BASE")" | tail -1)"
case "$fs" in ext4|xfs|btrfs|zfs|tmpfs) ok "$(dirname "$HOST_BASE") is $fs -- supports idmapped (shift=true) bind mounts" ;;
  *) warn "$(dirname "$HOST_BASE") is $fs -- idmapped mounts may not work; see README (raw.idmap fallback)";; esac
avail_gb="$(df -BG --output=avail "$(dirname "$HOST_BASE")" | tail -1 | tr -dc 0-9)"
if [ "${avail_gb:-0}" -ge 300 ]; then ok "${avail_gb} GB free"
elif [ "${avail_gb:-0}" -ge 60 ]; then warn "${avail_gb} GB free under $(dirname "$HOST_BASE"): enough for the cluster and the current MPI/GROMACS stack, NOT for the full CUDA/ML stack -- attach a data disk at /srv later (README, Disk)"
else warn "only ${avail_gb} GB free under $(dirname "$HOST_BASE")"; fi
if [ -n "${HOST_SCRATCH:-}" ]; then
  sd="$(dirname "$HOST_SCRATCH")"
  if mountpoint -q "$sd"; then ok "temp/scratch disk at $sd: $(df -h --output=size,avail "$sd" | tail -1 | xargs) (ephemeral -- build stages only)"
  else warn "$sd is not a separate mount; HOST_SCRATCH will live on the OS disk"; fi
fi

say "GPUs (PCI)"
lspci -Dnn | grep -iE 'vga|3d controller' | grep -i nvidia || warn "no NVIDIA PCI devices seen"
echo
echo "  Display GPU (boot_vga=1):"
for d in /sys/bus/pci/devices/*; do
  [ -f "$d/boot_vga" ] && [ "$(cat "$d/boot_vga")" = 1 ] && echo "    $(basename "$d") $(lspci -s "$(basename "$d")" | cut -d' ' -f2-)"
done
echo "  Kernel driver in use:"
lspci -Dk | awk '/^[0-9a-f]+:[0-9a-f]+:/ {dev=""} /^[0-9a-f]+:[0-9a-f]+:.*NVIDIA/ {dev=$1} dev && /Kernel driver in use/ {print "    "dev" -> "$NF; dev=""}'
lspci -Dk | grep -A3 NVIDIA | grep -q 'Kernel driver in use' || echo "    (no driver bound to the NVIDIA device yet -- expected before 01)"

say "NVIDIA driver"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  ok "nvidia-smi works"
  nvidia-smi --query-gpu=index,pci.bus_id,name,memory.total,compute_cap,driver_version,mig.mode.current --format=csv
  nvidia-smi | sed -n '3p'
else
  warn "nvidia-smi missing or failing: $(nvidia-smi 2>&1 | head -1)"
fi
lsmod | grep -q '^nouveau' && warn "nouveau is loaded (01-host-nvidia.sh blacklists it)" || ok "nouveau not loaded"
echo "  Installed NVIDIA packages:"; dpkg -l | awk '/^ii/ && /nvidia/ {print "    "$2" "$3}' | head -30
echo "  Held packages: $(apt-mark showhold | tr '\n' ' ')"
if command -v mokutil >/dev/null 2>&1; then echo "  Secure Boot: $(mokutil --sb-state 2>&1 | head -1)"; else echo "  Secure Boot: mokutil not installed"; fi
command -v ubuntu-drivers >/dev/null 2>&1 && { echo "  ubuntu-drivers --gpgpu candidates:"; ubuntu-drivers list --gpgpu 2>/dev/null | sed 's/^/    /'; }
dpkg -l unattended-upgrades 2>/dev/null | grep -q ^ii && warn "unattended-upgrades installed: can swap NVIDIA userspace under a running module (01 holds the packages)"

say "Container tooling"
if command -v lxc >/dev/null 2>&1; then ok "LXD: $(lxc version 2>/dev/null | tr '\n' ' ')"
  snap list lxd 2>/dev/null | awk 'NR==2{print "  snap lxd: version "$2", tracking "$4}'
  lxc list -c ns4 2>/dev/null || true
else echo "  LXD not installed (02-host-lxd.sh installs the snap)"; fi
command -v incus >/dev/null 2>&1 && warn "incus is also installed -- do not mix with LXD on the same bridge names"
if command -v docker >/dev/null 2>&1; then
  warn "Docker present: it sets iptables FORWARD policy DROP, which silently breaks LXD bridge egress (02 adds a DOCKER-USER rule)"
  iptables -S FORWARD 2>/dev/null | head -2 | sed 's/^/    /'
else ok "no Docker"; fi
command -v ufw >/dev/null 2>&1 && echo "  ufw: $(ufw status 2>/dev/null | head -1)"
grep -q "^root:" /etc/subuid && ok "root subuid range: $(grep '^root:' /etc/subuid)" || echo "  no root subuid entry (snap LXD manages its own)"

say "Network"
ip -br -4 addr | grep -v '^lo' | sed 's/^/  /'
echo "  default route: $(ip route show default | head -1)"
for u in https://github.com "${ACTIVATE_URL}" https://developer.download.nvidia.com; do
  code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)"; [ "$code" = 000 ] && code=unreachable; echo "  $u -> $code"
done
ip -4 route | grep -q "${LXD_SUBNET%.*}" && warn "subnet ${LXD_SUBNET} already routed -- change LXD_SUBNET in config.env" || ok "subnet ${LXD_SUBNET} is free"

say "Summary to paste back"
echo "  OS=${VERSION_ID} kernel=$(uname -r) threads=$(nproc) mem=$(free -g | awk '/Mem:/{print $2}')G free_disk=${avail_gb}G fs=$fs"
echo "  nvidia: $(nvidia-smi --query-gpu=pci.bus_id,name,driver_version --format=csv,noheader 2>/dev/null | tr '\n' ';' || echo none)"
echo "  NVIDIA PCI addresses: $(lspci -Dnn | awk '/NVIDIA/ && /(3D|VGA)/ {printf "%s ", $1}')"
echo "  config.env currently: GPU_PCI=(${GPU_PCI[*]})"
echo
echo "Log saved: $TB_LOG"
