> **Layout note (post-consolidation):** this document predates the move to the
> `parallelworks/workflows` repo. In this repo each workflow lives at
> `workflows/<name>/` with its variant YAMLs under `yamls/` and a single,
> unsuffixed script generation (`controller.sh`, `start-template.sh`) — version
> suffixes only exist in the old `interactive_session` repo history.

# Delivering Singularity containers as SIF files (ORAS on ghcr.io)

> Working notes from the **n8n** conversion (`n8n-endpoint` branch, 2026-07), where
> the sandbox-tarball delivery (`ghcr.io/parallelworks/n8n:1.0` — an `n8n.tgz`
> holding an unpacked sandbox directory) was replaced by a **SIF file**
> (`ghcr.io/parallelworks/n8n:2.0`). Ground truth:
> `workflows/n8n/n8n-singularity/{build-container.sh,controller.sh,start-template.sh}`.
> Everything below was verified on live runs on a cloud cluster unless marked otherwise.

## Operational notes (learned from live runs)

- **Pull SIFs through `tools/oras/libs.sh:oras_pull_file`** (or replicate its retry
  loop): ghcr intermittently answers `toomanyrequests` to anonymous pulls, and a
  single-attempt pull fails the whole run over a hiccup measured in milliseconds.
- **Keep the ghcr package public.** An anonymous pull of a private package fails with
  403 `unauthorized`; verify with an anonymous manifest request before shipping a
  workflow that references it.

## Why SIF instead of a tarballed sandbox

| | sandbox + tgz (old) | SIF (new) |
|---|---|---|
| Artifact | tar of a sandbox directory (tens of thousands of small files inside) | one compressed, mountable image file (n8n: 255 MB) |
| Install | `oras pull` + `tar -xzf` (double disk during extract, slow untar on shared filesystems) | `oras pull`, done |
| Runtime | runs anywhere — it's a plain directory | needs the node to be able to mount squashfs → **probe + sandbox fallback** (below) |
| Build | `singularity build --sandbox` + `tar -czf` | `singularity build <name>.sif docker://<image>` |
| Integrity | none (loose files, easy to corrupt with a partial untar) | single file; SIF is checksummed at build |

The only thing the sandbox bought us was independence from squashfs mount support.
Keep that as a **fallback built on demand from the SIF** — building a sandbox from a
local SIF is pure unpacking, needs **no internet**, so it is safe on compute nodes.

## Build and push

Build (see `n8n-singularity/build-container.sh`):

```bash
export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp     # build scratch off /tmp
export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache # OCI layer cache
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"
singularity build --force n8n.sif docker://n8nio/n8n:1.123.4
singularity exec n8n.sif n8n --version   # smoke-test before pushing
```

No upstream image (e.g. a pip-installed app)? Build from a definition file instead —
`singularity build --force --fakeroot app.sif app.def` works unprivileged on
apptainer 1.4.5 (verified: `streamlit-singularity/streamlit.def` on a cloud cluster, 2026-07);
bootstrap from `docker://python:3.12-slim` and `pip install` in `%post`.

Push as a plain ORAS artifact with the repo's own oras binary (`tools/oras/oras`):

```bash
printf '%s' "$GHCR_TOKEN" | tools/oras/oras login ghcr.io -u <github-user> --password-stdin
tools/oras/oras push ghcr.io/parallelworks/<name>:<tag> <name>.sif
tools/oras/oras logout ghcr.io   # so later pull tests exercise the anonymous path
```

- **Package visibility is inherited by new tags.** `parallelworks/n8n` was already
  public, so pushing `2.0` needed no GitHub admin action. Verify anonymous access
  without any stored credentials:
  ```bash
  TOKEN=$(curl -s "https://ghcr.io/token?service=ghcr.io&scope=repository:parallelworks/<name>:pull" | jq -r .token)
  curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      https://ghcr.io/v2/parallelworks/<name>/manifests/<tag>   # 200 = public
  ```
  Send the OCI `Accept` header: without it ghcr answers **404** for a public ORAS
  artifact (and 401 for a private one), which looks like a missing tag (verified 2026-09-16).
  A brand-new package is **private by default** and must be made public in the
  GitHub UI (Package settings → Danger Zone) before workflows can pull it.
- **Version by tag, don't overwrite:** `n8n:1.0` = legacy sandbox tgz (still used by
  the pre-SIF controller on older branches), `n8n:2.0` = SIF. Old workflow versions keep
  working.
- Pull with **oras**, matching how it was pushed. A plain `oras push` records the
  generic artifact type (`application/vnd.unknown.artifact.v1`), not the SIF media
  type that `singularity pull oras://` expects — stick to the repo's
  `oras_pull_file` helper (untested: `singularity push`/`pull oras://` as an
  alternative pair).

## Runtime: try the SIF, fall back to a sandbox

Some nodes cannot mount SIF images (no squashfs kernel/FUSE support, locked-down
setuid). Probe with the cheapest possible container run — **on the node that runs
the service**, not the login node: with `scheduler: true` the service lands on a
compute node whose support can differ, so the probe belongs in the **start
template**, never the controller. From `workflows/n8n/n8n-singularity/start-template.sh`:

```bash
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    container_ref="${container_sif}"          # mount works: run the SIF directly
else
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then        # unpack once, reuse afterwards
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi
# ...later: singularity run ... "${container_ref}"
```

- The probe covers every failure mode at once (kernel squashfs, squashfuse, setuid,
  userns) — no need to diagnose which one is missing.
- The fallback build is **offline-safe** (local unpack) and idempotent via the
  directory guard. Keep the sandbox at a distinct path (`containers/<name>-sandbox`)
  so it can't be confused with a legacy extracted sandbox at `containers/<name>`.
- Both branches verified on a cloud cluster: the live run took the SIF branch
  (`Apptainer runtime parent: n8n.sif` in `ps`), and the fallback build + a sandbox
  `n8n --version` were exercised manually on the same node.

## Recipe: convert a sandbox-tgz workflow to SIF

Using n8n as the template (diff the old sandbox controller → the SIF controller in the `interactive_session` history):

1. **Build script** — replace `build --sandbox` + `tar` with a single
   `singularity build <name>.sif docker://<image>:<tag>`; update the push hint to
   the new ghcr tag (`n8n-singularity/build-container.sh`).
2. **Build, smoke-test, push** the SIF as above; verify anonymous pull returns 200.
3. **Controller** — keep the install-dir fallback and idempotency guard; swap
   `oras_pull_file <repo>:<old> <name>.tgz` + `tar -xzf` for
   `oras_pull_file <repo>:<new> <name>.sif` + a non-empty check + `chmod a+r`.
   The guard changes from `[ -d dir ]` to `[ -f file.sif ]`.
4. **Start template** — point at the SIF, add the probe + sandbox fallback block
   above, and pass `container_ref` to `singularity run`. Everything else about the
   launch is unchanged (binds, `--env`, `--writable-tmpfs` all work the same for a
   SIF as for a sandbox).
5. **Test both branches**: a live run that uses the SIF directly, and a manual
   `singularity build --fakeroot --force --sandbox <dir> <sif>` +
   `singularity exec <dir> <app> --version` on the target node to prove the
   fallback works there.

## Ollama conversion notes (`ollama-gguf-container`, verified 2026-08)

Verified on a cloud cluster (apptainer 1.4.5, CPU) and an AWS GPU cluster (singularity-ce 4.4.2,
A10G GPU):

- SIF built from the official image (`docker://ollama/ollama:<tag>`), pushed as
  `ghcr.io/parallelworks/ollama-gguf:<tag>` (same tag as the release).
- One YAML serves both runtimes: a `service.name` **dropdown**
  (`ollama-gguf` | `ollama-gguf-container`) feeds `sparse_checkout` and the
  `workflows/<name>/.../controller.sh` / `start-template.sh` paths (the
  kasmvnc-container pattern). Add `tools/oras` to `sparse_checkout` — the
  container controller sources `tools/oras/libs.sh`.
- The launcher passes the endpoint port with `--env
  OLLAMA_HOST="127.0.0.1:\${PORT}"`; add `--nv` when `nvidia-smi -L` succeeds —
  in-container ollama then reports `library=CUDA` and loads models 100% GPU.
- The host model store is shared with the native variant
  (`--bind ${service_parent_install_dir}`; `OLLAMA_MODELS` env) so weights
  download once regardless of runtime. Controller-side pulls run a temp
  in-container server on an ephemeral port, same as the native flow.
- `pw endpoints delete` kills the **whole in-container tree** (apptainer
  starter → `ollama serve` → `llama-server` runner) on both apptainer and
  singularity-ce, and leaves sibling endpoints' trees untouched (verified with
  two ollama endpoints on one node).

## An image that needs root: a `--fakeroot` instance (verified 2026-10, `workflows/gitlab/gitlab-singularity`)

An official image whose init `chown`s and `setuid`s to several accounts cannot run as the
user, but runs unchanged as an Apptainer **instance** under `--fakeroot`: the user
namespace maps the image's accounts onto the user's subuid range. The SIF is a plain
conversion of the image (`gitlab.def`: `Bootstrap: docker`, nothing added), delivered as
above. What the start template decides, on the node that runs the service, and why; the
GitLab specifics (ports, configuration, stop command) are in [gitlab.md](gitlab.md):

- **Runtime**: `apptainer` first, then `singularity`, from the PATH or its module, taken
  only when `--version` answers (a module can ship an engine that panics on the node);
  the chosen name goes into every invocation, `cancel.sh` included (the kasmvnc pattern).
- **Range probe**: `exec --fakeroot <image> awk 'NR > 1 { print $3 }' /proc/self/uid_map`
  must print 65536 or more, or `chown` to the image's accounts fails. Login nodes of the
  cloud clusters have a range, their compute nodes none; a hardened system may map
  exactly 65536, so a user id above that owns nothing the namespace's root can write to.
- **Image probe**: `exec --fakeroot --writable-tmpfs <sif> sh -c 'touch /opt/x'` (the
  image needs a writable layer; `/bin/true` alone passes on the extraction fallback). It
  works: `instance start --fakeroot --writable-tmpfs <sif>`. It fails (a hardened node:
  `fusermount3` without `user_allow_other`, no rootless overlay, `noexec` `/tmp`):
  `build --fakeroot --sandbox <rundir>/image <sif>` once (ownership kept) and
  `instance start --fakeroot --writable <rundir>/image`, one sandbox per run directory
  since `--writable` mutates it, on a local disk only (a sandbox on a parallel filesystem
  returns truncated reads). A marker names the SIF the sandbox came from.
  `APPTAINER_TMPDIR`/`SINGULARITY_TMPDIR` go under the run directory.
- **State probe**: an actual `chown` in the run directory through the container. A
  network filesystem (NFS, Lustre, GPFS: the home of most HPC systems) refuses the mapped
  id's chown, since its server sees the user's own id, and a `stat -f` type check misses
  half of them. Works: bind the state directories. Fails: one ext3 **overlay image**
  (`overlay create --fakeroot --sparse --size <MiB> <rundir>/x.img`: Apptainer 1.3
  refuses an `upper/` the user owns under `--fakeroot` and records no whiteout in the
  image, so a deleted file stays; probe a delete and send such runtimes to a local
  disk; `instance start --overlay` in
  place of `--writable-tmpfs` and the binds; fuse2fs below fuse-overlayfs, the kernel
  checks permissions; needs `fuse2fs` and `mkfs.ext3` of e2fsprogs) with the init's
  service directory bound from the host (through the overlay `runsvdir` never saw the
  services the configuration added and the boot hung). Not **image binds**
  (`--bind x.img:/path:image-src=/dir`): fuse2fs alone checks permissions itself and
  refuses to write into a file just created read-only (0500 or 0444: unpacked binaries,
  git objects) and to unlink it. Not `--fusemount host:fuse2fs`: that fuse2fs is a
  libfuse2 program, takes no `/dev/fd` mount point and hangs. A first boot through the
  image takes about twice as long.
- **Instance flags**: `--contain --cleanenv --uts --hostname <host> --workdir
  <rundir>/work`, with `work/tmp` pre-created `1777` (Ruby's `Dir.tmpdir` rejects less; a
  `/tmp` bind is overridden by `--contain`'s own on singularity-ce). `--writable` creates
  no mount point, so every bind destination must exist in the image, inside an image too
  (a `mkdir` through a bind of its root). A host in FIPS mode shows the container
  `/proc/sys/crypto/fips_enabled` = 1, which breaks an Ubuntu image's OpenSSH (`PRNG is
  not seeded`): `--bind <file holding 0>:/proc/sys/crypto/fips_enabled` (Docker: `-v
  <file>:/proc/sys/crypto/fips_enabled:ro`).
- **Run and stop**: `exec --cleanenv --pwd / instance://<name> <entrypoint>` in the
  launcher's foreground, `exec instance://<name> <command>` for the setup; instances
  always get a PID namespace (`--pid` is not a flag of `instance start`). A `TERM` to the
  host-side `exec` never reaches the script inside, so `cancel.sh` runs the image's own
  stop command through `exec instance://` and then `instance stop -F`.
- **Cleanup and tests**: what the container writes belongs to mapped ids, so a run
  directory is removed from a `--fakeroot` exec; a leftover check counts processes whose
  mount namespace still binds the run directory (`grep -l <rundir> /proc/[0-9]*/mountinfo`),
  since `ps -u $USER` misses them.

## An image that needs root, rebuilt to run as the user (verified 2026-11, `workflows/gitlab/gitlab-singularity`)

The `--fakeroot` instance above needs a subuid range, a writable layer and a filesystem
that takes the namespace's `chown`, which NFS, Lustre and GPFS refuse. The sturdier
option is a **single-user image**: the official image rebuilt so that every service runs
as the one account the container runs as, from a **read-only** image. Nothing is chowned,
no range or writable layer is needed, the run directory is the user's own on any
filesystem, and it runs wherever an unprivileged container runs at all (the SIF, or the
directory it was extracted into). The recipe (`gitlab.def`, `rootless/`):

- **Accounts.** Bind a generated `/etc/passwd` and `/etc/group` that map the running
  uid/gid to every account the package uses: the one the services should be named after
  first (`getpwuid` returns the first match), `root` among the rest, so a resource that
  insists on `owner 'root'` finds the file already owned as it wants.
- **Privilege drops.** `chpst -u`, `su` and `setuidgid` fail without root even for the
  current user: a wrapper in the binary's place drops the `-u` option when not root. A
  same-uid switch in library code (Mixlib::ShellOut `user:`) is allowed and needs nothing.
- **Writes outside the volumes.** Every path the package writes under its install
  directory becomes a symlink baked into the image, pointing into the data volume and
  seeded on first start from a copy kept in the image. Links the configuration run
  creates inside read-only trees are created at build time; ones it would delete stay
  (a dangling link is harmless where the reader checks `File.exist?`, fatal among Rails
  initializers, where a small file that loads the target if it exists takes its place).
- **Root checks.** Patched out at build time by a script that names the exact text it
  replaces and fails the build when a new version moved it.
- **Bind destinations** exist in the image (`mkdir -p` at build time): a runtime
  without overlay or underlay creates none.
- **Finding the writes.** Run once in a writable sandbox you own (`apptainer build
  --sandbox` without fakeroot makes every file yours), `touch marker` before,
  `find <sandbox> -newer marker -not -path '<sandbox>/var/*'` after; then run the
  read-only image and fix what it still trips over, one resource per iteration.
- **Entrypoint.** The image's init without its root-only parts (chown, host keys,
  sysctl): seed the redirected directories, clean stale pids and sockets, start the
  supervisor with a clean environment, run the configuration, wait; `TERM` runs the
  package's stop command. A service the package only runs as root (OpenSSH) gives way
  to its unprivileged equivalent (gitlab-sshd).

Verified: every service as the user's uid, API, project creation, HTTP push and SSH
clone, no file in the run directory owned by another id; also from an extracted image
on an NFS home of a compute node without a subuid range, where a cold start took over
12 minutes against about 5 on a login node's local disk (size the wait budget for it).

## Gotchas (def-file builds — verified, rag-service 2026-08)

- **Upgrade pip first in `%post`** when bootstrapping from `python:3.9-slim`: its
  bundled pip rejects wheels from `download.pytorch.org` with
  `inconsistent Name: expected 'jinja2', but metadata has 'Jinja2'` and the build
  dies. `pip install --upgrade pip` before anything else fixes it.
- **CPU-only torch shrinks the SIF dramatically**: `pip install torch==<v>+cpu
  --index-url https://download.pytorch.org/whl/cpu` *before* `-r requirements.txt`
  (PEP 440 ignores the `+cpu` local label, so a plain `torch==<v>` pin stays
  satisfied). rag-service: 453 MB SIF instead of multi-GB with the CUDA stack.
- Keep the app code OUT of the environment container (deliver it via checkout) so
  code iterations never need a rebuild/re-push.

## Gotchas

- `singularity build` from `docker://` needs internet — build on the login node or
  your own machine, never in the start template.
- Set `SINGULARITY_TMPDIR` **and** `SINGULARITY_CACHEDIR` under `${HOME}` for both
  build and fallback: `/tmp` is often too small for image builds and is not shared
  across nodes. (Apptainer also accepts the `APPTAINER_*` names; the `SINGULARITY_*`
  ones still work everywhere this repo targets.)
- `--fakeroot` on the fallback build preserves in-container ownership without
  requiring sudo (works on the cloud cluster's apptainer 1.4.5 out of the box).
- `chmod a+r` the pulled SIF (the controller may run as a different user than a
  scheduled job in some setups; matches the old `chmod -R a+rX` on sandboxes —
  and is much cheaper: one file instead of a whole tree).

## Gotchas from live runs (added 2026-09)

- **`oras pull` says `denied` for a public package:** a stale ghcr login in the
  user's `~/.docker/config.json` on the cluster is being sent. `tools/oras/libs.sh`
  pulls anonymously first for this reason — reuse it instead of calling oras directly.
- **Container entrypoints that `pkill` by name kill sibling jobs:** singularity shares
  the host PID namespace, so the KasmVNC image's start-up `pkill -u $(id -u) -f Xvnc`
  killed the same user's other desktop starting on that node (verified on emed: two
  concurrent starts killed each other). Run such containers with `--pid` (works
  unprivileged with `--userns`; probe it, some sites disable PID namespaces) and anchor
  every `pkill -f` pattern you write to `cancel.sh` (`"Xvnc :${N}( |$)"`, not `"Xvnc :${N}"`).
  Test with two runs pinned to one node (`#SBATCH --nodelist=<node>`).
