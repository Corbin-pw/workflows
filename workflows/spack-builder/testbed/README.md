# DarpaNodes testbed — virtual Ubuntu 22.04 Slurm cluster on one host

A Slurm cluster in LXD system containers on one host. It mirrors the
customer's Ubuntu 22.04 cluster so the `spack-builder` workflow
(`workflows/spack-builder` in this repo, branch `DarpaNodes-Improvements`) can be
developed and run through ACTIVATE as an **existing** cluster before it goes to
production.

```
 host: Azure NC16as_T4_v3 · Ubuntu 22.04 · EPYC 7V12 (zen2) 16 vCPU · 108 GB · 512 GB disk · Tesla T4 · driver (host only)
 ├─ /srv/darpa-tb/software ──bind(shift)──> /software   (Spack root: /software/spack)
 ├─ /srv/darpa-tb/home     ──bind(shift)──> /home       (shared homes, like NFS)
 ├─ /mnt/darpa-tb-scratch  ──bind(shift)──> /scratch    (Azure temp disk: build stages, wiped on deallocate)
 └─ lxdbr-tb 10.42.0.0/24 (NAT)
     ├─ tb-ctl 10.42.0.10   slurmctld · login/build node · ACTIVATE agent   cap 16 CPU / 52 GiB
     ├─ tb-c1  10.42.0.11   slurmd · T4 (shared) · Slurm CPUs=8            cap 16 CPU / 24 GiB
     └─ tb-c2  10.42.0.12   slurmd · T4 (shared) · Slurm CPUs=8            cap 16 CPU / 24 GiB
```

CPU and memory limits are caps, not reservations: all three nodes share the
host's 16 vCPUs; Slurm advertises 8 per compute node. The single T4 is passed into both compute nodes.

All settings are in `config.env`. Every script logs to `logs/<script>-<timestamp>.log`.

## Getting the scripts onto the VM

They live in the repo, so clone the branch on the VM and run them from there:

```bash
git clone -b DarpaNodes-Improvements https://github.com/parallelworks/workflows.git
cd workflows/workflows/spack-builder/testbed
sudo ./00-preflight.sh
```

`logs/` and `activate-agent.cmd` (it holds a token) are git-ignored.

## Run order

| Step | Command | What it does | Done when |
|---|---|---|---|
| 0 | `sudo ./00-preflight.sh` | Read-only survey: OS, Azure VM size, CPU, RAM, disks, GPU PCI address, driver, Secure Boot, LXD snap, Docker/ufw, network | Summary printed; the NVIDIA PCI address matches `GPU_PCI` in `config.env` |
| 1 | `sudo ./01-host-nvidia.sh` | Host driver (≥570 server branch, open modules, signed prebuilt), nouveau blacklist, package holds, persistence mode | `nvidia-smi` lists both GPUs (reboot and re-run if told) |
| 2 | `sudo ./02-host-lxd.sh` | LXD snap (refreshes a preinstalled 5.0 snap to 5.21 LTS), pool, bridge, node profile, `/srv/darpa-tb/*`, `/scratch` on the temp disk, Docker/ufw forwarding fixes | Prints the GPU LXD can see |
| 3 | `sudo ./03-create-nodes.sh` | Creates `tb-ctl`, `tb-c1`, `tb-c2` (static IPs, CPU/mem caps, the T4 in both compute nodes via `nvidia.runtime`) | Every node: booted, internet OK, `nvidia-smi -L` in the compute nodes |
| 4 | `sudo ./04-provision-nodes.sh` | Base toolchain + Lmod, `/etc/hosts`, `pwuser` (UID 5001) + ssh key, munge, Slurm (apt), `slurm.conf`/`gres.conf` | `sinfo -N -l` shows compute nodes idle |
| 4b | `sudo ./04b-slurm-pmix.sh` | Builds Slurm `SLURM_VERSION` from source with PMIx on `tb-ctl` (~10 min), swaps it in for the apt Slurm on every node, sets `MpiDefault=pmix` | `srun --mpi=list` includes `pmix` |
| 5 | `sudo ./05-verify-cluster.sh` | Munge, shared FS, ssh, srun/sbatch, PMIx launch, headers, GPU through `--gres`, userns for Apptainer | `all N checks passed` |
| 6 | `sudo ./06-activate-agent.sh` | Runs `activate-agent.cmd` as `pwuser` on the controller: pw CLI install + agent **service** install (see below) | Cluster shows connected in ACTIVATE |
| — | `sudo ./99-destroy.sh [--purge]` | Removes nodes (keeps `/srv` data), or everything | |

Every step can be re-run safely. `03 --recreate` rebuilds the nodes and keeps `/software` and `/home`.

## How the testbed differs from production

| Area | Testbed | Customer cluster (to confirm) | Effect on the workflow |
|---|---|---|---|
| Node isolation | LXD containers sharing the host kernel (6.8 azure) | Bare-metal/VM Ubuntu 22.04, kernel 5.15/6.x | Userland (glibc 2.35, gcc 11) matches exactly |
| Slurm | 25.11.x source build with PMIx (after 04b); apt 21.08 before | PMIx supported (confirmed); version unknown | See assumptions A1-A4 |
| Job confinement | `proctrack/linuxproc`, `task/none` (no cgroups) | probably `cgroup` | Jobs are not CPU/GPU fenced; set `CUDA_VISIBLE_DEVICES` per job |
| Shared FS | Host bind mounts (idmapped) | NFS/Lustre/… | Same paths and UIDs; no NFS locking semantics |
| GPU driver | Host driver injected via `nvidia.runtime` | Driver on each node | `nvidia-smi` / `libcuda` present in the nodes; no toolkit at `/usr/local/cuda` unless installed |
| CPU target | `zen2` (AVX2, no AVX-512) | ? | Spack binaries built here target zen2; production needs a build for its own microarchitecture (or a generic `x86_64_v3` stack) |
| GPUs | 1x T4 (sm_75, 16 GB) shared by both nodes | ? | `cuda_arch=75` here. Multi-GPU code (cuFFTMp, NVSHMEM, multi-GPU NCCL) can be built and linked, not run at scale |
| CPU count | 16 vCPU shared by 3 nodes | ? | Builds run at -j16 on the controller |
| `/software` | root-owned, `/software/spack` owned by `pwuser` | ? | Login-time `MODULEPATH` hook in `/etc/profile.d` needs root once |

## ACTIVATE agent (step 6)

`/home` is shared, so the pw CLI installed into `pwuser`'s home is on every node. `activate-agent.cmd` (git-ignored, it holds a token) is run as a bash script by `pwuser` and holds three lines:

```bash
export PATH="$HOME/pw:$HOME/.local/bin:$PATH"   # so the agent line finds the CLI installed by the next line
<pw CLI install command from ACTIVATE>
<agent SERVICE install command from ACTIVATE>
```

Use the **service** install: the nodes restart whenever the VM is stopped, and a manually started agent would not come back. Check that the unit runs as `pwuser`, not root:
`sudo lxc exec tb-ctl -- bash -c 'systemctl list-units --all | grep -iE "pw|agent"'`.
It installs as a systemd **user** service of `pwuser` (seen in job environments: `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/5001/bus`), so 06 enables linger for `pwuser`. Without linger the service only runs while `pwuser` has a session and does not come back after a restart. The agent runs on `tb-ctl` only. It is the login node, and jobs reach the compute nodes through Slurm. Installed and connected 2026-11-09.

## Customer cluster assumptions

No direct access to the customer cluster yet. Known: Ubuntu 22.04, Slurm with PMIx. Everything else is assumed. Each assumption is a `config.env` setting, so it can change when the real values are known.

| # | Assumption | Setting | Why this guess | How to confirm on the customer cluster | If wrong |
|---|---|---|---|---|---|
| A1 | Slurm **25.11.x**, built from source (not Ubuntu's 21.08 package) | `SLURM_VERSION` | Ubuntu 22.04's package has no PMIx, so a PMIx site must build its own. 25.11 is the previous supported release line (26.05 is current). | `sinfo --version` | Change `SLURM_VERSION`, `sudo ./04b-slurm-pmix.sh --rebuild` |
| A2 | PMIx **4.1.x** from Ubuntu's `libpmix-dev` | `PMIX_SOURCE` | Easiest PMIx a 22.04 site can build Slurm against | `srun --mpi=list` (shows pmix / pmix_v4 / pmix_v5), `dpkg -l \| grep pmix`, `pmix_info --version` | A self-built PMIx 5.x means 04b builds PMIx too |
| A3 | `MpiDefault=pmix` | `SLURM_MPI_DEFAULT` | Lets plain `srun` launch OpenMPI 5 | `scontrol show config \| grep MpiDefault` | Set to `none`; jobs then pass `--mpi=pmix` |
| A4 | Slurm, PMI2 and PMIx **headers installed** on the nodes | built in by 04b | A site that builds Slurm usually leaves the headers | `ls /usr/include/slurm/slurm.h /usr/include/slurm/pmi2.h; find / -name pmix.h` | The workflow's header probe drops `mpich +slurm` and `openmpi +pmix` |
| A5 | **Lmod** reads Tcl modulefiles | `MODULES_PKG` | Most common on Ubuntu HPC sites | `module --version` | Set `environment-modules`, re-run 04 |
| A6 | Login node can reach GitHub and the source mirrors | (none) | Needed for login-node builds | `curl -sI https://github.com` | Build on a compute node, or pre-fetch sources and use a mirror |
| A7 | Not confined by cgroups in the testbed, probably confined in production | `slurm.conf` | Containers cannot use cgroup confinement reliably | `scontrol show config \| grep -E 'Proctrack\|TaskPlugin'` | Testbed jobs see all CPUs and the GPU, production jobs may not |
| A8 | Unknown CPU microarchitecture and GPU models | (workflow inputs) | | `spack arch`, `nvidia-smi -L` | The testbed builds for zen2 / sm_75; production needs its own target |

## Disk and build time on this VM

- **Disk:** the 512 GB OS disk holds the cluster, the Spack root, the build cache and the full CUDA/ML stack.
- **Temp disk:** `/mnt` is Azure's ephemeral resource disk. It is exposed as `/scratch` for Spack build stages only, never for installs, and it is wiped on deallocate.
- **CPU:** 16 vCPU is twice the workflow's 8-core reference. Expect roughly 30 min for `gcc@14.2.0` and 1-1.5 h for a cold build of the current stack. Source builds of PyTorch/JAX are possible, but they take hours each and need lots of memory per compile job, so cap `-j` for them.

## Troubleshooting

- **Nodes have no internet:** Docker's `FORWARD DROP` policy or ufw. Step 02 adds rules for both. Check with `sudo iptables -S DOCKER-USER`.
- **`nvidia-smi` missing in a node:** check `lxc config show tb-c1 | grep nvidia` and the host's `nvidia-smi`. LXD needs the host driver *before* the container starts: `lxc restart tb-c1`.
- **`Driver/library version mismatch`:** the host driver was upgraded without a reboot. Step 01 holds the packages to prevent this.
- **Files in `/home` show up as `nobody`:** the host filesystem doesn't support idmapped mounts. Use `raw.idmap` instead (ask Claude).
- **slurmd won't start after 04b:** `sudo lxc exec tb-c1 -- journalctl -u slurmd -n 40`. If it complains about `cgroup.conf`, delete `/etc/slurm/cgroup.conf` on the nodes (lib/slurm.sh writes `CgroupPlugin=disabled` for source builds) and restart.
- **A node is `down`/`drain` in `sinfo`:** `sudo lxc exec tb-c1 -- tail -50 /var/log/slurm/slurmd.log`, then `scontrol update nodename=tb-c1 state=resume`.

## Open questions (fill in as answered)

1. Customer Slurm version and `srun --mpi=list`, and whether they have Slurm/PMIx dev headers (assumptions A1-A4).
2. Customer module system: Lmod or environment-modules (Tcl)? Current `MODULEPATH`?
3. Which account owns `/software` there, and does the workflow get `sudo` for the `/etc/profile.d` hook?
4. Customer CPU microarchitecture and GPU models (sets the Spack target and `cuda_arch`).
5. ~~ACTIVATE onboarding~~ Resolved: pw CLI + agent service on the login node (see "ACTIVATE agent").
