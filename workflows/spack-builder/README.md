# Spack MPI Stack Builder

Builds a Spack **v1** multi-MPI HPC stack on a SLURM/PBS cluster and generates Tcl
modules, publishing everything to a binary build cache so later runs install in
minutes instead of hours.

**This is a build workflow, not an endpoint/session service.** It runs to
completion and exits. It does register a `pw` endpoint at the end, but that
endpoint is a placeholder serving an empty page — see
[The placeholder endpoint](#the-placeholder-endpoint).

## What gets built

| | |
|---|---|
| Compiler | `gcc@14.2.0`, built with the system compiler, then used for everything else |
| MPIs | `openmpi@5.0.10`, `mpich@4.2.2`, `intel-oneapi-mpi@2021.13.0` |
| Applications | `gromacs@2025.4`, one build per MPI |
| Validation | `osu-micro-benchmarks`, one build per MPI |
| Optional GPU path | CUDA-aware `openmpi+cuda` and `gromacs+cuda` |
| Additional software | Any Spack specs listed under **Additional Spack packages** (default: `apptainer`, `cmake`, `git +tcltk`, `git-lfs`), and **Additional MPICH versions** (default `3.4.3`) beside the default MPICH |

The three MPIs coexist in one environment via `concretizer: unify: false`.

## Where the build runs

**Run the build on** (`cluster.build_on`) picks the node that compiles:

- **Login node** (default) — it has internet for source fetches and no queue
  walltime, which is why it is the default: on many clusters it is the only node
  that can download anything.
- **Compute node** — the build is submitted as a job to the same partition, GPUs
  and extra directives as the inspection job, with its own walltime
  (`cluster.slurm.build_time`, default `08:00:00`; on PBS put
  `#PBS -l walltime=...` in the build job directives). The worker must reach
  github.com and the source mirrors. This compiles on the hardware the stack is
  for, so the target is always `exact`. A build killed at its walltime leaves no
  exit status, and `verify` says so.

  On SLURM the build job is one task on one node (`--nodes=1 --ntasks=1`)
  requesting `--cpus-per-task` = **Parallel build jobs**, capped by the
  `size_build` job at the inspected worker's **physical** cores and at the CPUs
  Slurm configures for it (`app/cpu-counts.sh`). Hyperthreads are not counted: a
  cloud worker launched with hyperthreading disabled can still be configured in
  Slurm with its instance type's vCPU count, and the gce `c2-standard-4` workers
  have 4 vCPUs but only 2 Slurm CPUs. Without the request SLURM gives the job a
  single CPU whatever `-j` says. `build.sh` then caps `-j` at the CPUs the job
  was actually given. On PBS request the CPUs in the build job directives
  (`#PBS -l select=1:ncpus=8`); `-j` is still capped at what the job sees.

The option is hidden when there is no scheduler or inspection is turned off.
Spack is still bootstrapped and the build cache configured on the login node by
`controller.sh` in both modes.

### Re-running a failed login-node build on a worker

Right after concretizing, `build.sh` downloads the source of every spec it is
about to compile (`app/prefetch-sources.py`) into Spack's source cache,
`$SPACK_ROOT/var/spack/cache`, which sits on the shared filesystem. Spack checks
that cache before any mirror or URL. So when a login-node build fails, typically
on a header the login image lacks, re-run it with **Run the build on: compute
node**: the worker unpacks every source from the cache and downloads nothing.
The log prints one `cached` / `downloaded` line per spec and a summary, so a
worker run shows whether it touched the network. Specs that the binary cache
can supply, externals and already-installed specs are skipped. Sources Spack
cannot cache (a git branch, for example) are named in a warning. Dry runs
(`concretize_only`) stop before this step.

The build stage itself (`$tempdir/$user/spack-stage`) is node-local and is not
shared. Only the downloaded archives are.

### Site externals always come from the worker

`spack external find` runs on **both** nodes — the login node in `controller.sh`
and the inspected worker in `detect-fabric.sh` — through `app/find-externals.sh`,
and each result is saved to the run directory (`externals.head.yaml`,
`externals.compute.yaml`) and printed in the log together with that node's
system compilers. `Inspect head node` diffs the two.

The build then applies the **compute** file to the site scope wherever it
compiles, because every binary runs on the workers: an external that exists only
on the login node would link and then be missing at run time. With full
overrides no worker is inspected; a worker build then discovers on its own node,
and a login build falls back to the login node's file with a warning.

## How it decides what to build for

By default the compile runs on the **login node**, but the stack is meant for
the **compute nodes**, which on most clouds are a different instance type. So a
short job runs on a worker first and reports its fabric, GPU and CPU
microarchitecture.

For a login-node build that split has a consequence worth understanding. Spack only emits code the build
host can run, and `packages: all: target:` is a *preference*, so an unsupported
target is silently dropped rather than rejected. `app/resolve-target.py` makes the
decision explicit:

- **Worker target is older than the login node** → build exactly for the worker
  (`exact`).
- **Worker target is newer, same lineage** (skylake_avx512 → cascadelake) → the
  login node cannot emit it, so the build falls back to the login node's own
  target and says so loudly (`fallback`). Those binaries still *run* on the
  worker — a newer microarchitecture on the same lineage is a superset; they just
  leave its newer instructions unused. Set **Run the build on** to a compute
  node if that last few percent matters.
- **The two are incomparable — different vendors** → neither target works, and
  falling back to the login node's would be silently wrong. The build targets the
  best **common ancestor** instead (`common`).
- **Different CPU family** (x86_64 login, aarch64 workers) → no target serves
  both, so the build **fails** rather than producing binaries that cannot run.

**Requesting the target is not enough — reuse has to be constrained too.**
`packages: all: target:` is a preference, and `reuse: true` outranks a
preference: an installed spec built for a different microarchitecture still
satisfies the request, so Spack takes it rather than building.

The environment therefore pins reuse to the chosen target:

```yaml
concretizer:
  reuse:
    include:
    - target=<the resolved target>
```

Reuse still does its job in the normal redeploy case, where everything cached is
already at the right target, and is refused for everything else — from the local
install tree and the build cache alike.

## Fabric handling

| Detected | Profile | Transport |
|---|---|---|
| EFA device present | `aws` | libfabric/OFI, EFA provider |
| Verbs device + Azure | `azure` | UCX over verbs |
| Verbs device + Oracle | `oracle` | UCX over verbs |
| GCP | `gcp` | OFI / verbs |
| No RDMA hardware | `generic` | TCP + shared memory |

Hardware is authoritative; cloud identity only breaks ties. The `aws` profile
*requires* an EFA-capable libfabric rather than pinning a version, so a cluster
whose EFA install cannot do EFA fails loudly instead of silently running over TCP.

## Build cache

Every package built is pushed to `buildcache_path` (default
`${HOME}/spack-buildcache`), a directory-backed Spack mirror, and later runs
install from it. Notes:

- The mirror is **unsigned** — it is a private path only this account can write,
  and requiring a GPG keyring would make every fresh cluster a manual step.
- Pushes use `--private` because `intel-oneapi-mpi` is non-redistributable and is
  skipped silently otherwise, leaving a hole exactly where the slowest package is.
- On a cold cache Spack warns `cannot be used in concretization (no index found)`.
  That is expected: an empty mirror cannot be indexed. The index appears with the
  first push.
- Install paths are padded (`padded_length: 128`) so the cache stays
  **relocatable**. Without padding Spack refuses to move a package into a longer
  prefix (`CannotGrowString: ... because the new prefix is longer`), which ties a
  build cache to the exact install root that produced it. Verified both ways on
  an unpadded cache: redeploying into a *shorter* root worked in seconds and the
  binaries ran with no references to the original prefix, while a *longer* root
  failed outright. 128 leaves headroom for any target root up to 128 characters.
  The stack compiler is installed outside the environment, so `build.sh` also
  sets the same padding in the Spack root's site scope
  (`config:install_tree:padded_length:128`), which every command then shares. 
  Before that, gcc and its dependencies were cached unpadded and a run into a 
  longer root failed on them.

### Archiving and redeploying the build cache

The cache is a plain directory, so the robust way to move it is to tar it and
copy it — no symlinks are involved, and `build.sh` pushes with `--update-index`,
so the index is current and no extra sync step is needed:

```bash
tar -czf spack-buildcache.tar.gz -C "$(dirname "$buildcache_path")" "$(basename "$buildcache_path")"
```

Two things to know before shipping one:

- **Relocation is what padding buys.** With `padded_length: 128` the binaries can
  be unpacked and installed under a different root. An *unpadded* cache can only
  ever move to a root no longer than the one it was built in.
- **The cache contains `intel-oneapi-mpi`,** because `build.sh` pushes with
  `--private` (without it Spack silently skips non-redistributable packages and
  leaves a hole where the slowest package should be). Intel oneAPI has
  redistribution terms, so keep such an archive in a private bucket, or push
  without `--private` to omit it.

## Redeployment: what a warm cache is worth

Measured on `aws`, run `charming-mongoose` (recorded as
`tests/general/buildcache-redeploy.json`). The cluster had been rebuilt, `${HOME}`
held nothing but a copied `spack-buildcache`, and `${HOME}/spack` and
`${HOME}/.spack` were deleted before the run:

| | |
|---|---|
| Whole run, submission to endpoint | **7 min 43 s** |
| Cache forecast after concretization | 66 of 66 buildable specs cached, 4 external |
| What the install did | 36 specs from the build cache, **0 compiled from source** |
| Against a cold build of the same stack | ~1.6 h at `-j8` |

Afterwards all three MPIs load with a working `mpirun` and
`gromacs/2024.3-openmpi-5.0.10` reports `2024.3-spack` — from binaries alone, on a
machine that had no Spack on it ten minutes earlier. (That run predates the
GROMACS 2025.4 bump below, so its cached GROMACS specs no longer apply; the
measurement of what a warm cache is worth still stands.)

Note the install paths contain literal `__spack_path_placeholder__` components.
That is the `padded_length: 128` padding on disk, not a relocation failure; it is
exactly what makes the cache relocatable into a different root.

## Build times (rule of thumb)

**Budget roughly 2 hours on 8 cores for a cold CPU-only build.** One measured
sample: 100 packages, ~1.6 h wall clock at `-j8` on the `generic` profile with an
empty cache.

`gcc@14.2.0` is ~30 min of that and everything waits on it, so a second run
against the same prefix and target is far quicker — it comes back from the build
cache. The rest is cheaper than "three MPIs and three GROMACS" sounds: Intel MPI
is a prebuilt tarball that never compiles, and CPU-only GROMACS is minutes per
build. More cores help sublinearly, since gcc's bootstrap does not parallelise
well. Times exclude cloning Spack and downloading sources, which are
internet-bound rather than CPU-bound.

## Overrides

`target`, `fabric` and `cuda-arch` are **all-or-nothing**: set all three to skip
hardware inspection entirely (no worker is allocated), or none to inspect. Partial
overrides are rejected. Use `cuda-arch=none` to force a CPU-only build.

## Options worth knowing

- **Stop after concretizing** (`concretize_only`) bootstraps Spack, sets up the
  build cache, inspects the hardware, renders and concretizes — then stops before
  the long compile. This is the fast way to validate a new cluster or a spec
  change, and it is what the recorded test uses.
- **Spack root** (`install_prefix`, default `/software/spack`) must be on a
  filesystem shared between login and compute nodes. A missing root (and build
  cache) is created with `sudo -n` and handed to the user running the workflow;
  Spack itself never runs as root. `${HOME}/spack` keeps everything in user
  space and needs no sudo at all (turn off the login hook too). An existing root is reused, never deleted: a git
  clone is switched to the requested tag only if it is on a different commit; a
  usable Spack that is not a git clone is used as found, with a warning if its
  version differs; and any other non-empty directory, or an unreadable `.git`
  from an interrupted clone, fails the run with a message naming the path.
  Every install is padded (below), including the stack compiler, so cached
  binaries relocate into any root up to 128 characters. Cache *hits* for the
  stack are still tied to the root, though: the built gcc is registered as an
  external, an external's hash includes its path, and every stack package
  depends on it. A different root puts gcc at a different path, so its stack
  packages get new hashes and are compiled rather than taken from the cache.

## Site install: `/software/spack`, one module folder, MODULEPATH at login

The defaults install a site stack rather than a personal one:

| Input | Default | |
|---|---|---|
| Spack root | `/software/spack` | Spack clone and install tree |
| Module tree root | `/software/spack/modulefiles` | |
| Binary build cache | `/software/spack-buildcache` | outside the root, so it survives deleting the root |
| One module folder | on | `modules:default:arch_folder:false` -- `MODULEPATH` is exactly the module root |
| Add the modules to every user's MODULEPATH at login | on | needs passwordless sudo |

**One module folder.** Spack normally files modules under
`<root>/<platform>-<os>-<target>`, and the external gcc under a second, generic
target (see below). With this on, everything lands in `<root>/<name>/<version>`
and the gcc module sits beside the stack. One CPU target per root: the root
records its target in `.spack-builder-target`, and a run for another target
fails instead of overwriting the first stack's modules.

**MODULEPATH at login.** The `login_hook` job, after the execution check, writes
two files:

- `<Spack root>/etc/profile.d/spack-modules.sh`, owned by the workflow user,
  rewritten every run: prepends the module tree to `MODULEPATH` once (POSIX sh,
  safe to source repeatedly);
- `/etc/profile.d/z99-spack-builder-modules.sh`, root-owned, on the login node
  and every compute node Slurm can reach: it only sources the first file, so
  root is needed once and later module-path changes need none.

Passwordless sudo is **required** when the option is on, and `controller.sh`
checks it before anything is built. A node Slurm cannot reach within two
minutes is reported as a warning with the one command to run there. Batch jobs
inherit `MODULEPATH` from the submitting shell; `module` itself is available in
`#!/bin/bash` batch scripts (Lmod's `BASH_ENV`), not under `sbatch --wrap`,
which runs `/bin/sh`.

Future direction (not implemented): move the privileged steps to Ansible
playbooks, so sudo can be authenticated interactively once instead of requiring
passwordless sudo.

## Where the modules go, and holding several stacks

The module tree root is the `module_root` form input (default
`/software/spack/modulefiles`), not a fixed path under the Spack root, because a
cluster is expected to hold more than one stack. The rest of this section
describes the per-architecture layout used when "One module folder" is off.

Spack keys the tree by **spec** architecture — `<root>/<platform>-<os>-<target>`
— so stacks built for different targets already separate themselves. Point
separate stacks at separate roots when you want them independent beyond that.

One consequence catches everyone: a *single* stack spans **two** of those
directories. The packages carry the stack target (`linux-rocky9-skylake_avx512`),
while the external compiler carries a generic one (`linux-rocky9-x86_64`), so the
`gcc` modulefile is filed apart from everything built with it. Both belong on
`MODULEPATH` — see "After the build".

## The GPU path: CUDA version and libraries

**What was already here, and what the DarpaNodes-Improvements branch added.**
The GPU path itself predates this branch: **Build the GPU path** already added
a CUDA-aware OpenMPI and `gromacs +cuda` to the CPU stack, read the GPU's
compute capability on a worker and applied it as `cuda_arch` to every package,
used a CUDA toolkit found on the compute nodes or let Spack build one, failed
early when no usable GPU was inspected, and gave the CUDA builds their own
module names (next section). The branch extends it:

| Upstream | Added on this branch |
|---|---|
| CUDA from the compute nodes, else whatever Spack picks (13.4 at the time, past the nvcc 13.2 GROMACS link failure under Known gaps) | **CUDA toolkit version** input, default 12.9.1; a node toolkit older than 12.8 fails the run before anything is built |
| CUDA-aware OpenMPI, `gromacs +cuda` | **GPU libraries** input: cuDNN, NCCL, NVSHMEM, cuFFTMp, each with a module; `osu-micro-benchmarks +cuda` for device-buffer tests |
| The `generic` fragment's GROMACS GPU spec used a bare `^openmpi+cuda`, which under `unify: false` is a second openmpi | every consumer of the cuda-aware MPI shares one openmpi (bug fix) |
| -- | GPU checks in `testbed/07-test-stack.sh` |

With **Build the GPU path** on, the environment gains, next to the CPU stack:

| Root | Notes |
|---|---|
| `cuda@<CUDA toolkit version>` | default **12.9.1**; pinned only when Spack builds CUDA |
| CUDA-aware OpenMPI | the fabric fragment's `cuda_aware_mpi_specs` |
| `gromacs +cuda` | single-GPU build (see below) |
| `osu-micro-benchmarks +cuda` | device-buffer latency/bandwidth (`-d cuda D D`) |
| GPU libraries | default `cudnn nccl nvshmem cufftmp`, each with a module |

**Why 12.9.1.** Spack refuses gcc 14 -- the stack compiler -- with CUDA 12.6 or
older (`conflicts("%gcc@14:", when="%cuda@:12.6")` in
`build_systems/cuda.py`), so the lowest usable toolkit is 12.8, above the
customer minimum of 12.4. cuFFTMp is published for CUDA 12 only
(`cufftmp@11.4.0.6`, `..._cuda12-archive`), and GROMACS 2025.4 failed to link
against nvcc 13.2 (Known gaps). A toolkit already on the compute nodes is used
instead, and the run fails before building anything if it is older than 12.8.

**One cuda-aware MPI.** Every root that links the cuda-aware MPI --
`gromacs +cuda`, `osu +cuda`, `nvshmem`, `cufftmp` -- carries the fragment's
*whole* `cuda_aware_mpi_specs` string (`render-env.py`, `gpu_specs()`), because
under `unify: false` a bare `^openmpi+cuda` concretizes to a different openmpi
(the same trap as the CPU path's MPI requirements). The `generic` fragment's
GROMACS spec used the bare form; it is rewritten at render time.

**GROMACS stays single-GPU.** Its `+cufftmp` and `+nvshmem` variants depend on
`nvhpc`, the whole NVIDIA HPC SDK (10 GB+), not on the standalone `cufftmp` and
`nvshmem` packages, and they only pay off with several GPUs. cuFFTMp and
NVSHMEM are still installed as libraries for users' own codes.

## Python environments and Conda/Mamba

**Build Python environments** makes one virtual environment per line of the
**Environments** input (`name: pip requirements`), each on a Spack-built
`python@<Python version>` (default **3.11**), each with its own module
`<name>-env` (e.g. `ml-env`, `esm3-env`; not `py-*`, which Spack uses for its
Python packages). Packages come from PyPI; nothing depends on conda or on
Anaconda's channels. The default list:

```
ml:   torch jax[cuda12] transformers numpy biopython mdtraj biotite scikit-learn openmm[cuda12]
esm3: esm httpx
```

Why two environments, found by resolving the list for Python 3.11 on
manylinux 2.35 x86_64 before building anything:

- **ESM-3** (`esm` 3.2.1) requires `transformers<4.48.2` and pulls `torchtext`
  0.18, which is discontinued and was built for torch 2.3. In one environment
  every user gets a January-2025 Transformers, or (forcing a current one) the
  resolver silently drops ESM-3 to 3.0.3.
- `esm` 3.2.1 imports `httpx` in its SDK (`esm.sdk.api`) without declaring it;
  the line adds it, and the build's import check covers `esm.models.esm3` and
  `esm.sdk.api`, not just the top-level package.
- `fair-esm` (ESM-2) and `esm` (ESM-3) both install the import name `esm`.
  ESM-2 is served by Transformers instead (`facebook/esm2_*`).

**Python 3.11 is behind "latest".** These packages' newest releases need 3.12:
JAX 0.12 (3.11: 0.10.2), ESM-3 3.5 (3.11: 3.2.1), NumPy 2.5 (2.4.6), MDTraj
1.11.2 (1.11.1), Biotite 2.0 (1.6.0). Set **Python version** to 3.12 for a
second, newer set of environments; the existing ones stay.

**Updates are additive.** An environment's directory
(`<Spack root>/envs/py-<name>-<pyver>-<hash>`) is named by a hash of the Python
version and its requirements. An unchanged line reuses it; a changed line
builds a new directory and module version next to the old one, and the
module's `.version` default moves to the newest. `requirements.lock.txt` in each
records the exact versions. A package that installs but does not import (a
compiled extension built for another torch, say) fails the run.

**Install Conda/Mamba** adds module `miniforge3` for users' own environments:
Miniforge from conda-forge (the repo's `tools/utils/miniforge.sh`), a
`.condarc` that lists only conda-forge and re-points the name `defaults` at it,
and environments/package caches in `~/.conda`. conda, mamba and conda-forge are
free to use; Anaconda's `defaults` channel needs a paid licence for larger
organisations, so it is never configured.

## Updating and extending an existing install

**Re-running the workflow against the same Spack root extends it.**
- Every run builds a fresh environment from the form, so you can add packages or change versions freely.
- Installs from earlier runs stay on disk and are reused when they match.
- Modules are refreshed without `--delete-tree`, so earlier modules stay too.
- Nothing is uninstalled.

New versions are installed beside the old ones:

- **Packages the stack does not pin** (anything under Additional Spack packages): change the version on its line, for example `cmake@3.31` to `cmake@4.1`. The next run installs it next to the old one.
- **Packages the stack pins** (the MPIs): add a line with the new version, for example `openmpi@5.0.11`. The pin becomes `one_of`, so both versions are installed (see "Additional software" below).

**The newest version becomes the module default.**
- After each run, `set-module-defaults.py` writes `module-version <name>/<module> default` into `<name>/.modulerc` for every package that has more than one version. Older versions still load by their full name.
- Several modules of one version, such as GROMACS per MPI, are alternatives rather than an update, so the script does not choose a default among them.
- The Python environments and Miniforge set their own defaults in `.version`, and the script leaves them alone.

**Only a Spack root this workflow created is changed.**
- The workflow re-points its Spack root to the requested tag and writes site config there (`packages.yaml`, mirrors). It must not do that to a Spack someone else maintains.
- A root it created carries a `.spack-builder` marker. Roots from before the marker existed are recognised by the `packages.yaml` the workflow copies in on every run.
- A Spack root without either is refused, and the error says what to do instead.

**Building on a Spack you did not create: Existing Spack to build on.**
- Enter that Spack's root, or its install tree. It is chained read-only as a Spack upstream (`etc/spack/upstreams.yaml` in the new Spack root), and new builds go into the Spack root, which must be a different path.
- The controller log shows its install database version and lists its explicitly installed packages, such as the site's GROMACS builds. That list is what a later run can rebuild at a new version beside them.
- Clearing the input removes the chain.

Limits of upstreams, from Spack's own documentation:
- Spack writes **no modules** for packages it takes from an upstream. Users keep loading those from the existing module tree. If the existing Spack keeps a module index (`module-index.yaml`), it is configured, so modules built here can autoload the upstream ones.
- Upstream packages are reused only where they match this stack's requirements: same target, gcc 14.2.0, the pinned versions and variants. Anything else is built fresh in the new root.
- Upstreams are not locked. Do not install into, or uninstall from, the existing Spack while a run uses it.
- Spack v1 reads install databases v6 to v8 (Spack v0.16 and newer) from an upstream without reindexing. Older databases are refused.

## Additional software and extra MPI versions

**Additional Spack packages** is an editor with one Spack spec per line; `#`
starts a comment. Each line becomes a root of the environment and gets a
module. Any package the configured Spack repositories and mirrors offer can be
listed. The defaults cover the customer list's tools:

| Line | Module(s) | Notes |
|---|---|---|
| `apptainer` | `apptainer` | Built without the setuid starter, so it runs through unprivileged user namespaces (the cluster must allow them; Ubuntu 22.04 does by default). |
| `cmake` | `cmake` | The newest release. Projects that still declare `cmake_minimum_required` below 3.5 need CMake 3.x; add `cmake@3.31` as another line. |
| `git +tcltk` | `git` (+ `tk`, `tcl`) | `+tcltk` installs the two Git GUIs, `git gui` and `gitk`. They need an X display (`ssh -X`, or a desktop session). |
| `git-lfs` | `git-lfs` | |

"Git Desktop" (GitHub Desktop) has no official Linux release, so `git gui` and
`gitk` are the GUIs provided. A community Linux build of GitHub Desktop exists,
but it is an Electron app outside Spack and is not installed.

How a line is applied, so that the stack keeps one build per package:

- **Variants on a line become a requirement on that package.** `git +tcltk`
  also adds `packages: git: require: ["+tcltk"]`. Without it, any other root
  that depends on git would concretize its own copy with default variants
  under `unify: false`, and two builds of one name and version abort
  `module tcl refresh` with "Name clashes detected" (the same failure the ucx
  requirement in `fabric-azure.yaml` fixes).
- **A version of a package the stack already pins is installed alongside it.**
  The template pins each MPI (`openmpi: require: ["@5.0.10"]`). A line such as
  `openmpi@4.1.6` widens that pin to `one_of: ["@5.0.10", "@4.1.6"]`. Specs that
  name no version (`gromacs ^openmpi`, `osu-micro-benchmarks ^openmpi`) still
  resolve to the newer pinned version, which is already installed; the extra
  version is used only where a spec names it.
- **Lines with a dependency clause (`^`) or compiler (`%`) are added as roots
  only.** No package requirement is derived from them.
- Already-installed packages are reused. A re-run with more lines adds them
  and removes nothing.

**Additional MPICH versions** (space-separated, default `3.4.3`) installs each
version next to the default `mpich@4.2.2`, with an
`osu-micro-benchmarks ^mpich@<version>` build for testing. They use the
default MPICH's device, network and PMI. On a cluster whose Slurm offers PMIx,
that is `pmi=pmix`. MPICH 3.4 has PMIx support for the ch4 device, and with
`--with-pmix` it replaces its built-in PMI and process manager (its
`configure.ac`), so it launches with `srun --mpi=pmix` like 4.2.2. The
`MPIR_CVAR_PMI_VERSION` set in every MPICH module does not exist in 3.4 and is
ignored there. Before it was added, a scratch build of 3.4.3 (ch4:ofi,
`--with-pmix`) compiled and linked cleanly with gcc 14.2, libfabric 2.6.0 and
PMIx. That build covered compiling only; the multi-node launch is checked by
`07-test-stack.sh` (passed on the testbed). Its module is `mpich/3.4.3-gcc-14.2.0`, and `module load mpich`
still loads 4.2.2.

The testbed's `07-test-stack.sh` checks each of these:

- Each MPI module version: compile, a multi-node hello world (which also checks the library version), and OSU latency and bandwidth.
- `module load mpich` still loads the newest version.
- Apptainer: pulls `docker://busybox` to a SIF and runs it on a compute node as the user.
- CMake: the version is at least 3.23, and a project configures and builds with gcc 14.
- Git: a commit in a new repository works; git-gui and gitk are installed, and gitk's wish binary exists.
- git-lfs: a file is stored as an LFS pointer.

## Module names in a GPU build

A GPU environment holds a `~cuda` and a `+cuda` build of the same
name/version/compiler — `openmpi`, `gromacs`, `fftw`, `hwloc` and others — and
the CPU projections name both identically, so `module tcl refresh` aborts with
`Name clashes detected in module files`. That happens **after** a fully
successful install, which is how `caring-warthog` managed to build and push the
entire GPU stack and still fail.

GPU builds therefore get a `-cuda` suffix where it applies, and otherwise the
same names as a CPU build:

```
gromacs/2025.4-openmpi-5.0.10-cuda     GPU build
gromacs/2025.4-openmpi-5.0.10          CPU build
```

- a **`-cuda` suffix**, which means exactly one thing: *this package is
  CUDA-enabled*. The constraint is `+cuda` on the package itself.

  It must **not** be written `^mpi+cuda`. A variant constraint on a *virtual* is
  silently dropped, so that degenerates to `^mpi` and matches every MPI build:

  ```
  ^mpi+cuda      → dtymywh dzhjyzk tf5yvlt 7izjiju   (all four — wrong)
  ^openmpi+cuda  → tf5yvlt 7izjiju                   (concrete provider — correct)
  +cuda          → 7izjiju                           (the package itself)
  ```

  A previous run consequently labelled its `mpich~cuda` and
  `intel-oneapi-mpi` GROMACS builds `-cuda`, though neither they nor their MPI
  had any CUDA — three of four builds mismarked, the opposite of the point.
  Constrain the concrete provider, or the package, and matching behaves.

  Two rules, in this order: `+cuda ^mpi` first, so a CUDA-enabled package that
  links an MPI keeps the MPI in its name; then `+cuda` alone, which catches the
  CUDA-aware MPIs themselves — they *provide* mpi rather than depend on it, so
  they never match the first rule. The result carries one suffix per genuinely
  CUDA-enabled spec:

  ```
  gromacs/2025.4-openmpi-5.0.10-cuda-7izjiju    gromacs+cuda
  gromacs/2025.4-openmpi-5.0.10-tf5yvlt         gromacs~cuda on CUDA-aware openmpi
  gromacs/2025.4-mpich-4.2.2-dzhjyzk            gromacs~cuda
  openmpi/5.0.10-gcc-14.2.0-cuda-uoyrl2w        openmpi+cuda
  mpich/4.2.2-gcc-14.2.0-embhosw                no CUDA anywhere
  ```
- **`^hwloc+cuda` gets `-cuda` too.** `pmix` and `prrte` each appear twice with
  *identical* variants, differing only in which `hwloc` they were built
  against. This was first solved with a hash suffix (`hash_length: 7`) on
  every GPU module, which gave each module a different name in a GPU run than
  in a CPU run. One flat folder then held two modules per version (testbed,
  2026-11-24). Names no longer depend on the run type, so a later run updates a
  module in place.
- **Anything that still clashes gets a hash, for that version only.** On the
  testbed GPU stack that was four implicit dependencies (`gettext`, `krb5`,
  `openssh`, a build-only `python@3.14.5`), each pulled in twice with
  different dependency subtrees. `build.sh` reads the clashing names from the
  failed refresh, gives just those `name@=version` a hash projection
  (`module-names.py hash-for`) and retries. Spack checks for clashes before it
  writes anything, so a failed attempt changes nothing.
- **Hidden implicit modules (`hide_implicits`) are not an option on Ubuntu
  22.04.** Its Lmod 6.6 aborts `module avail` and `module load` on the
  `module-hide` lines Spack writes ("invalid command name module-hide"),
  checked with `testbed/probes/module-naming-probe.sh`.

After each refresh, `module-names.py prune` removes modules left under an
outdated name for a build the refresh just wrote, identified by the `/hash`
on the modulefile's header line (for example the hashed names of GPU runs
from before this change). It never removes a different build, or a file
Spack did not write.

Spack picks the first projection whose constraint the spec satisfies, in the
order they are written, with `all` reserved as the fallback — see
`get_projection` in `lib/spack/spack/projections.py`.

## After the build

The build ends with a `=== DONE ===` banner that prints these paths for the
stack it just built. Take them from there rather than composing them by hand;
the shape is

```bash
export MODULEPATH=<module_root>/<arch>:<module_root>/<generic-arch>:$MODULEPATH
module load gcc/<gccver>-none-none              # gcc/g++/gfortran, to compile
module load openmpi/<version>-gcc-<gccver>      # or mpich / intel-oneapi-mpi
module load gromacs/<version>-openmpi-<version>
```

which on a `skylake_avx512` CPU stack installed with the default module root is

```bash
M=$HOME/pw/software/modules
export MODULEPATH=$M/linux-rocky9-skylake_avx512:$M/linux-rocky9-x86_64:$MODULEPATH
```

**Two directories, and `MODULEPATH` must name them, not their parent.** The
`depends-on` lines Spack writes into every modulefile are *bare* names
(`gcc-runtime/14.2.0-none-none`), resolved against a `MODULEPATH` entry. Point
`MODULEPATH` at `$M` and the modules are named `linux-rocky9-skylake_avx512/…`
instead, so every one of those requirements misses and the load aborts:

```
$ export MODULEPATH=$HOME/pw/software/modules
$ module load linux-rocky9-skylake_avx512/openmpi
  ERROR: Unable to locate a modulefile for 'gcc-runtime/14.2.0-none-none'
  ERROR: Load of requirement gcc-runtime/14.2.0-none-none failed
```

Nothing loads, and — because the `module` command still returns 0 — the shell is
left on the *system* MPI, which is the same silent-wrong-direction failure
`external-modules.py` exists to prevent.

**The `gcc` module lives in the second tree**, the `<generic-arch>` one. The
stack compiler is registered as an *external* (the solver refuses to build the
provider of the `c` virtual, see `build.sh`) and `build.sh` excludes every
external from the module tree — but `include: [gcc, …]` in `spack.yaml.in` takes
precedence over `exclude` (`return not include_matches and (exclude_matches or
excluded_as_implicit)`, `lib/spack/spack/modules/common.py`), so `gcc` alone
comes back. It lands in a tree of its own because the external entry carries a
*generic* target (`x86_64`) while everything built with it carries the stack
target, and Spack files modules by the spec's architecture.

That second tree is what makes the stack usable for *building*, not just
running: it sets `PATH`, `MANPATH`, `CMAKE_PREFIX_PATH` and
`CC`/`CXX`/`FC`/`F77` to the Spack compiler. With only the first tree, `module
load openmpi` succeeds and `mpirun` works — every package is RPATH-linked and
`gcc-runtime` carries the runtime libraries — but no compiler lands on `PATH` to
compile anything new against it. `spack load gcc` does the same job without
modules.

Use the **full** module name. Plain `module load openmpi` can match a system
module of the same name earlier on `MODULEPATH` and silently give you the system
MPI instead.

Always run these binaries **through the module**, not by absolute path. Intel MPI
in particular needs the environment the module sets; invoked bare, `gmx_mpi` dies
in `MPIDI_OFI_mpi_init_hook -> open_fabric`.

The OSU binaries install under `libexec/osu-micro-benchmarks/mpi/...`, not `bin`,
so they are not placed on `PATH` by design.

Verified on this cluster: all three MPIs run `osu_latency` (0.25-0.56 us
intra-node) and all three GROMACS builds report `2024.3-spack` — measured before
the 2025.4 bump.

Launcher note: OpenMPI 5 dropped the `pmi` and `legacylaunchers` variants, and
this stack does not assume a PMIx plugin in Slurm. Check `srun --mpi=list` on your
cluster; where only `pmi2` is offered, launch with `mpirun` inside an allocation,
or `srun --mpi=pmi2`.

MPICH is built **without** `+slurm`: `--with-slurm` needs Slurm headers, and
`slurm-devel` is absent on images that ship only the Slurm runtime. `pmi=pmi2`
gives the integration that matters without them. On a cluster that does have the
headers, adding `+slurm` is a reasonable improvement.

MPI versions and fabric variants are stated as **package requirements**, not
inside each spec. `gromacs` and `osu` depend on a bare `^openmpi`/`^mpich`, and
under `unify: false` that otherwise concretizes to a different node than the
standalone MPI spec — building two copies of every MPI and linking GROMACS
against one while the module tree advertises the other.

## Layout

```
yamls/general.yaml        preprocess -> detect (worker) -> size_build -> build (login node or worker)
                          -> verify -> exec_check -> login_hook -> endpoint + wait_for_endpoint
app/controller.sh         login node: bootstrap Spack, head externals, build cache
app/detect-fabric.sh      worker: fabric + GPU + microarchitecture + CPU counts + externals probe
app/cpu-counts.sh         one node's logical CPUs, physical cores and Slurm CPUTot
app/find-externals.sh     discover one node's site externals / apply a node's file
app/site-externals.py     move the managed externals between site scope and a file
app/prefetch-sources.py   download every to-be-compiled source into the shared cache
app/build.sh              build node: apply worker externals, render, concretize,
                          install, push, modules
app/build-python-envs.sh  build node: Python venvs (PyPI) and the miniforge3 module
app/install-login-hook.sh login node: MODULEPATH at login on every node (sudo)
app/start-template.sh     login node: the placeholder endpoint
app/inspect-buildcache.py build cache inventory, integrity and hit/miss forecast
app/resolve-profile.sh    all-or-nothing override policy
app/resolve-target.py     reconcile worker target with what the build host can emit
app/render-env.py         spack.yaml.in + fabric fragment -> spack.yaml
app/packages.yaml         site externals baseline (policy, not versions)
app/templates/            environment template + 5 fabric fragments
tests/general/            recorded end-to-end test
testbed/                  virtual Ubuntu 22.04 Slurm cluster (LXD) for developing this workflow
```

## Known gaps and deferred work

- `undefined reference to void nbnxn_kernel_prune_cuda<false>(...)` plus
  `relocation R_X86_64_PC32 against undefined hidden symbol`. No library was
  missing; nvcc 13.2 emits such instantiations as hidden stubs the host
  translation unit cannot reference. Spack cannot warn about this: the package
  declares `depends_on("cuda", when="+cuda")` with **no upper bound**, so any
  GROMACS pairs with any CUDA and the mismatch appears only after the whole CPU
  stack has built (1h28m in that run). Both 2025.4 specs, CPU and GPU, were
  checked with `spack spec` before committing.
- **`cuda_arch` is set once under `packages: all: variants`, not per spec.** Only
  packages that *have* the variant pick it up. Setting it per-spec reached
  `gromacs` and missed everything transitive: in the same run `ucx` and `gdrcopy`
  concretized with `cuda_arch:=none`, and gdrcopy ran
  `nvcc --generate-code arch=compute_none,code=sm_none` → `nvcc fatal :
  Unsupported gpu architecture 'compute_none'`. One consequence worth knowing:
  inside a GPU run the CPU GROMACS specs also carry `cuda_arch`, so their hashes
  differ from the same specs built by a CPU-only run and the two cannot share
  cache entries. CPU-only runs are untouched — the key is only added when the GPU
  path is active.
- **A GPU build now fails when no usable GPU is reported**, instead of quietly
  producing the CPU stack. If inspection lands on a GPU-less node, or the node's
  GPUs are hidden from a job that requested none, the run stops in the first
  minutes with an actionable message rather than after two hours with the wrong
  artefact.
- The PBS path is untested.
- Heterogeneous clusters need one run per node type; the design assumes one
  representative worker.
- Thumbnails are placeholders.
- **Module flavour is Tcl.** If the site standard is Lmod, flip the template's
  `modules.default.enable` to `[lmod]` and add a `core_compilers` list — Lmod
  needs it to build its hierarchy.
- **NAMD is not built.** Spack's `namd` needs the NAMD source tarball, which
  is distributed only after registering at the UIUC site, so it cannot be
  fetched automatically. Once the tarball is on the cluster it can be added as
  an additional package (for example `namd@3.0.3`, with the tarball placed in
  a Spack source mirror). Deferred for now.
- **Deferred enhancements:** a GPU-aware OSU build (`-d cuda`) for device-buffer
  bandwidth numbers, and cuFFTMp to let GROMACS spread PME across multiple GPUs.

## Verifying the stack actually runs

A build exiting 0 and an endpoint answering HTTP say nothing about whether the
binaries can execute. By default the build happens on the **login node**, so a
stack compiled for the login node's ISA runs there perfectly and every recorded
criterion passes.

So the workflow runs the binaries on a compute node, in its own job
(`exec_check` + `exec_verify`). It has to be a separate submitted job: a check
that runs where the build ran proves nothing, because that is the node whose ISA
the binaries wrongly match.

`app/check-exec.sh` runs `gmx_mpi -version` for every GROMACS install in the
environment, **under that package's own run environment** (`spack load --sh`),
and separates two verdicts, which mean different things:

Running the bare binary path is not representative and produces false failures.
`intel-oneapi-mpi` needs `FI_PROVIDER_PATH` to locate the libfabric providers it
ships; without it `MPI_Init` aborts with `OFI fi_getinfo() failed ... No data
available` on a binary that is completely sound. `spack load --sh`
is used rather than `module load` deliberately: it produces the same environment
without touching the TCL module tree, whose name clashes in a GPU build are the
reason modules are avoided here at all.

- **SIGILL (exit 132)** -- the binary cannot execute on this CPU. This is the
  fault the job exists to catch, and it fails the run.
- **anything else** -- the binary started but its MPI could not initialise here.
  This warns rather than fails. It is a property of the launch environment, not
  of what was compiled: MPICH built `--with-pmi=pmi2` has no process manager to
  reach when run standalone (`write_line error; fd=-1`), and `intel-oneapi-mpi`
  aborts with `OFI fi_getinfo() failed` on a node with no suitable provider.
  Failing on those would fail a run on every cluster without an EFA device.

A non-SIGILL failure is retried once under the binary's own launcher, resolved
from the MPI it actually links against (`ldd`) rather than whatever `mpiexec` is
on `PATH`.

### Why it does not use `srun`

The job is submitted to the compute partition, so the script is already running
on a worker -- `srun` is not needed to reach one, and it cannot launch half of
these binaries anyway:

    $ srun --mpi=list
    none, cray_shasta, pmi2          # no pmix
    $ ls /usr/lib64/slurm/           # mpi_pmi2.so, libpmi2.so present
    $ ls /usr/include/slurm/pmi2.h   # missing, as is pmix.h

OpenMPI 5 dropped native PMI2 in favour of PMIx, and this SLURM has no pmix
plugin, so `srun ./gmx_mpi` cannot start the OpenMPI-linked builds -- the CUDA
one among them -- although they run perfectly standalone via singleton init.
Running directly and falling back to the binary's own launcher avoids PMI
negotiation entirely. This is the same split the header probe reports: the PMI
runtime libraries are installed, the headers to build against are not.

When the check does land on the node that built the stack -- which happens with
`scheduler=false`, where there is no separate compute node -- it says so with a
warning, because in that configuration it cannot detect a microarchitecture
mismatch at all.

## Header inventory: head node vs compute node

`spack external find` detects a package from its libraries, but Spack then
COMPILES against it, which needs the `-devel` headers. `prune-headerless-externals.py`
removes externals that lack them, but silently -- so a build that failed on a
missing `ucx` or `pmi2` header left nothing in the log saying which headers the
node actually had.

`app/probe-headers.sh` now records that inventory explicitly, on **both** nodes,
as part of the `detect` job:

- `Inspect compute node` writes `headers.compute.env` beside `fabric.env`.
- `Inspect head node` writes `headers.head.env`, and also logs the head node's
  own parameters -- microarchitecture, OS image, kernel, glibc, gcc, nvcc --
  which were never written down anywhere before. When a stack misbehaves on the
  worker the first question is how the two nodes differ, and that was
  unanswerable after the fact.

Probed: `UCX`, `LIBFABRIC`, `VERBS`, `RDMACM`, `SLURM`, `PMI2`, `PMIX`, `CUDA`,
`GDRCOPY`.

The two sets are then diffed, and the asymmetry matters:

- **present on compute, missing on head → the run fails loudly** for a
  login-node build. The build links on the head node, so such a header cannot be
  used no matter what the worker supports. This is the split-image case, and it
  otherwise surfaces as a configure error hours into a compile. When the build
  runs on a worker it is only a notice, since the head does not compile.
- **present on head, missing on compute → warning.** It builds, and may still
  run, because the runtime library can be present while only the headers are
  absent.

With full overrides the `detect` job is skipped entirely, so neither probe runs
and there is nothing to compare.

## The placeholder endpoint

The last two jobs (`endpoint`, `wait_for_endpoint`) start a `pw` endpoint named
`spack-builder-<run-slug>` that serves one static page: the run slug, the
resolved fabric profile and the `MODULEPATH` to use — read from
`modulepath.env`, which `build.sh` writes in the shared run directory, because
the endpoint job runs elsewhere with no Spack set up and cannot work the two
module trees out for itself. **Nothing in the build
needs it.** It exists because the shared end-to-end test runner
(`tools/tests/run-workflow-test.py`) passes a run only when

```python
row["result"], row["error"] = "fail", "run completed but no endpoint listed"
```

does *not* fire — an endpoint named `*-<run-slug>` must be listed and its URL
must answer. This is the only workflow in the repository that serves nothing, so
rather than teach the shared runner a new pass mode, it serves an empty page.

The endpoint outlives the run, exactly like a real service: `wait_for_endpoint`
touches the `SKIP_CLEANUP` marker once the endpoint answers and cancels the
submitter, so the run completes with the endpoint still up and the test runner
can find it, check it and then `pw endpoints delete` it. On a **cancel** — and on
any teardown that does not skip cleanups — `cancel.sh` deletes the endpoint
explicitly (`pw endpoints delete`) before killing the process group. Deleting it
is the part that matters: killing the process alone would leave a stale entry in
`pw endpoints list` that outlives the run.

Delete it by hand after a manual run:

```bash
pw endpoints delete spack-builder-<run-slug>
```

**This is expected to be removed.** The build is finished and the stack is usable
before the endpoint starts; it is scaffolding for the test framework, not a
feature. If the runner grows a way to express "this workflow serves nothing and
its result is a command that must succeed on the resource", these two jobs and
`app/start-template.sh` should go. Keep them only if a real use for a served page
appears — a browsable build log or module list would be one.

## Diagnosing a run from the logs alone

Whoever reads a failed run usually has no shell on the cluster, so the things
needed to explain a build are printed rather than left on the node:

| Question | Where the answer is printed |
|---|---|
| What is this node, and is the disk full? | `controller.sh` site facts: host, OS, kernel, cores, memory and `df -h` for `$HOME`, the Spack root and the cache — printed before anything can fail |
| Did the mirror index? | `controller.sh` reports the result of `spack buildcache update-index` instead of swallowing it. An unindexed mirror is silently ignored by the concretizer, and the only other symptom is that everything rebuilds |
| What is in the build cache, and did it arrive intact? | `inspect-buildcache.py` inventory: spec count, packages, and a blob-level integrity check (every manifest's blobs present and the exact size the manifest records) |
| Will this run use the cache, or compile for two hours? | `inspect-buildcache.py --lock` after concretization: hits, misses, and for each miss the same-named cached spec it collided with |
| Which hardware did the stack get built for? | `detect-fabric.sh` echoes the resolved `fabric.env`; `build.sh` prints the profile and the target decision. The login node's CPU model and `spack arch -t` are in the controller's site facts |
| Is there really a usable GPU, and which CUDA? | `detect-fabric.sh` logs the GPU model, compute capability, driver version, the driver's CUDA runtime and the toolkit's `nvcc` version — and logs *why* when `nvidia-smi` gives no answer, rather than leaving an unexplained empty `cuda_arch` |
| Why did a package fail to compile? | `build.sh` inlines the last 80 lines of each failing package's Spack build log, which otherwise only exists on the node |
| Did the build actually succeed? | `BUILD_STATUS` + the `verify` job. `script_submitter`'s unscheduled path detaches the script and polls `kill -0`, so it sees that the process ended but never its exit status |

### Reading the logs

```bash
pw workflows runs logs   <slug>            # everything, in order
pw workflows runs logs   <slug> --failed   # only failed steps
pw workflows runs errors <slug> -o text
```

**`--job build` matches nothing.** A submitted script's output is not filed under
the job name in this YAML: `script_submitter` contributes its own job names, so
everything the three submitted scripts print appears under `preprocessing`,
`slurm_job`, `ssh_job` and `stream_output` — and all three submissions share
them. Read the unfiltered log and search for the `=== [controller] ===`,
`=== [detect] ===` and `=== [build] ===` banners instead.

On the node, each submitted job gets its own directory under the run dir:

```
~/pw/jobs/<slug>/           inputs.sh, fabric.env, spack-env/, the assembled scripts
~/pw/jobs/<slug>/detect/    run.<JOBID>.out of the hardware probe
~/pw/jobs/<slug>/build/     run.<JOBID>.out of the build, spack-install.log, BUILD_STATUS
~/pw/jobs/<slug>/endpoint/  run.<JOBID>.out of the placeholder endpoint, endpoint-root/
```

They must stay separate: `script_submitter` streams to `run.${PW_JOB_ID}.out`
and all three submissions of a run carry the **same** `PW_JOB_ID`, so one shared
directory means each job truncates the previous one's log. That is how the aws
run `charming-mongoose` lost its entire build log to the endpoint job, leaving
the platform-side log as the only copy.

`fabric.env` is **sourced**, so every value it carries is quoted on write. Until
the GPU fields arrived every value was a single token — profiles, 0/1 flags,
paths, targets — so nothing needed quoting and nothing revealed the gap. The
first multi-word value (`GPU_NAME=NVIDIA H100 80GB HBM3`) made line 8 parse as an
assignment followed by the command `H100`, and `build.sh` aborted with status 127
before running anything. `bash -n` does not catch this; writing the file with
real values and sourcing it does.

A failing `spack install` prints the tail of `spack-install.log` itself, not only
the per-package logs Spack names. Those named paths point into the build stage,
which Spack removes when `install` exits, so by the time the handler runs they
are usually gone — on `hopeful-haddock` the loop found both paths and could read
neither. Spack's own streamed excerpt of the failing build (the `>`-marked lines)
is in `spack-install.log` and is what actually carried UCX's
`configure: error: RDMACM requested but required file (rdma/rdma_cma.h)`.

The integrity check compares **sizes**, not checksums: hashing a 1.4 GiB cache
on every run costs minutes, and the failure it guards against — an interrupted
copy or a full disk — truncates files, which a size check catches exactly.

A cache miss is reported as a *warning*, not an error, in both cases (damaged
blobs and no matching hash): Spack compiles what it cannot extract, so the run
still produces a correct stack. What the reader needs is the reason it suddenly
takes two hours, and the two causes look identical from the outside —

- **damaged**: manifests exist but blobs are missing or truncated → re-copy the cache.
- **complete but irrelevant**: every hash differs because this image resolved
  different externals, or the fabric profile or microarchitecture changed → working
  as designed; the run rebuilds and pushes, and the cache then serves both.

## Recorded tests

`tests/general/` holds the end-to-end tests, run by
`python3 tools/tests/run-workflow-test.py <test>.json`:

| test | what it covers |
|---|---|
| `cpu-smoke.json` | `concretize_only` into a throwaway Spack root on `aws`: bootstrap, externals, build cache, worker inspection, render and solve, in minutes rather than hours. The cheap way to validate a cluster or a spec change |
| `cpu-smoke-worker.json` | `cpu-smoke` with **Run the build on: compute node** — the scheduled build path, worker externals applied, in minutes |
| `aws-cpu-worker.json` | a full CPU install built on an `aws` `cpu` worker: install, push, modules and the exec check, all from a compute-node build |
| `buildcache-redeploy.json` | a full install on `aws` with a build cache already present — the redeployment case: a fresh cluster whose only Spack artifact is a copied `${HOME}/spack-buildcache` |
| `gce2-buildcache-redeploy.json` | the same redeployment on `gce2`, a different cloud and image: the externals differ, so it is also the test of whether a cache built elsewhere still applies |

Each sets a `warm_marker` on the Spack root and the cache, so the CSV records
whether a row was a cold, warm or partial start — for the redeploy tests,
`partial` (cache present, no Spack root) *is* the case under test.
