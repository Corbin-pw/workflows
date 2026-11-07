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
| 5 | `sudo ./05-verify-cluster.sh` | Munge, shared FS, ssh, srun/sbatch, GPU through `--gres`, userns for Apptainer | `all N checks passed` |
| 6 | `sudo ./06-activate-agent.sh` | Runs the ACTIVATE agent command (from `activate-agent.cmd`) as `pwuser` on the controller (or `--all`) | Cluster shows connected in ACTIVATE |
| — | `sudo ./99-destroy.sh [--purge]` | Removes nodes (keeps `/srv` data), or everything | |

Every step can be re-run safely. `03 --recreate` rebuilds the nodes and keeps `/software` and `/home`.

## How the testbed differs from production

| Area | Testbed | Customer cluster (to confirm) | Effect on the workflow |
|---|---|---|---|
| Node isolation | LXD containers sharing the host kernel (6.8 azure) | Bare-metal/VM Ubuntu 22.04, kernel 5.15/6.x | Userland (glibc 2.35, gcc 11) matches exactly |
| Slurm | Ubuntu 22.04 apt `slurm-wlm` 21.08.x | ? | PMI/PMIx plugins and headers may differ: compare `srun --mpi=list` |
| Job confinement | `proctrack/linuxproc`, `task/none` (no cgroups) | probably `cgroup` | Jobs are not CPU/GPU fenced; set `CUDA_VISIBLE_DEVICES` per job |
| Shared FS | Host bind mounts (idmapped) | NFS/Lustre/… | Same paths and UIDs; no NFS locking semantics |
| GPU driver | Host driver injected via `nvidia.runtime` | Driver on each node | `nvidia-smi` / `libcuda` present in the nodes; no toolkit at `/usr/local/cuda` unless installed |
| CPU target | `zen2` (AVX2, no AVX-512) | ? | Spack binaries built here target zen2; production needs a build for its own microarchitecture (or a generic `x86_64_v3` stack) |
| GPUs | 1x T4 (sm_75, 16 GB) shared by both nodes | ? | `cuda_arch=75` here. Multi-GPU code (cuFFTMp, NVSHMEM, multi-GPU NCCL) can be built and linked, not run at scale |
| CPU count | 16 vCPU shared by 3 nodes | ? | Builds run at -j16 on the controller |
| `/software` | root-owned, `/software/spack` owned by `pwuser` | ? | Login-time `MODULEPATH` hook in `/etc/profile.d` needs root once |

## Disk and build time on this VM

- **Disk:** the 512 GB OS disk holds the cluster, the Spack root, the build cache and the full CUDA/ML stack.
- **Temp disk:** `/mnt` is Azure's ephemeral resource disk. It is exposed as `/scratch` for Spack build stages only, never for installs, and it is wiped on deallocate.
- **CPU:** 16 vCPU is twice the workflow's 8-core reference. Expect roughly 30 min for `gcc@14.2.0` and 1-1.5 h for a cold build of the current stack. Source builds of PyTorch/JAX are possible, but they take hours each and need lots of memory per compile job, so cap `-j` for them.

## Troubleshooting

- **Nodes have no internet:** Docker's `FORWARD DROP` policy or ufw. Step 02 adds rules for both. Check with `sudo iptables -S DOCKER-USER`.
- **`nvidia-smi` missing in a node:** check `lxc config show tb-c1 | grep nvidia` and the host's `nvidia-smi`. LXD needs the host driver *before* the container starts: `lxc restart tb-c1`.
- **`Driver/library version mismatch`:** the host driver was upgraded without a reboot. Step 01 holds the packages to prevent this.
- **Files in `/home` show up as `nobody`:** the host filesystem doesn't support idmapped mounts. Use `raw.idmap` instead (ask Claude).
- **A node is `down`/`drain` in `sinfo`:** `sudo lxc exec tb-c1 -- tail -50 /var/log/slurm/slurmd.log`, then `scontrol update nodename=tb-c1 state=resume`.

## Open questions (fill in as answered)

1. Customer Slurm version and `srun --mpi=list`. Do they have `libpmix`/`slurm` dev headers?
2. Customer module system: Lmod or environment-modules (Tcl)? Current `MODULEPATH`?
3. Which account owns `/software` there, and does the workflow get `sudo` for the `/etc/profile.d` hook?
4. Customer CPU microarchitecture and GPU models (sets the Spack target and `cuda_arch`).
5. Exact ACTIVATE "existing cluster" onboarding steps: agent on the login node only, or on every node?
