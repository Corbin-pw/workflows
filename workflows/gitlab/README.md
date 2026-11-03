# GitLab

Runs a self-hosted [GitLab](https://about.gitlab.com/) (repositories, merge requests,
issues, CI/CD) on a cluster's login node, from the official image under Singularity or
Docker, and serves it as a `pw` endpoint on a fixed subdomain. Users sign in with their
ACTIVATE account. Pipelines run on the cluster through GitLab runners: on the login
node, or on the compute nodes through SLURM with
[Jacamar CI](https://gitlab.com/ecp-ci/jacamar-ci).

A CI job runs as the Linux user whose runner picked it up, so the workflow has two
modes:

- **Start GitLab**, for the user who serves it. Starts GitLab and registers runners for
  a group that only this user owns.
- **Add my runners to a running GitLab**, for every other user of that GitLab. Starts
  runners on the same login node, as that user, for their own projects.

New to GitLab? The [tutorial](tutorial/README.md) takes you from the launch form to
pipelines on the login node, on your other ACTIVATE resources and on the compute
nodes, in about 45 minutes.

```
Start GitLab (the owner)
form ──► preprocessing ──► start script ──► GitLab answers, ──► https://<subdomain>.<sessions domain>/
         (checks, runner    (container,     group and runners    the run completes; GitLab and the
          tools)             runners)       registered           runners run until the session is deleted

Add my runners to a running GitLab (every other user)
form ──► preprocessing ──► start script ──► runners registered ──► a status page of the runners; the run
         (checks, runner    (finds the      and started            completes; the runners run until the
          tools)             GitLab's port)                        session is deleted
```

The first start of a run directory takes three to six minutes while GitLab configures
itself and creates its database. Later starts take two to four. The run completes once
the sign-in page answers and the runners are registered (until then the page answers
503 to the platform's probe). GitLab and its runners keep running until the session is
deleted. Adding runners takes under a minute.

## Two ways to run it

| Run container using | What runs | Needs |
|---|---|---|
| **Singularity** (default) | The official image rebuilt to run as **one unprivileged user** (`ghcr.io/parallelworks/gitlab:19.5.1-ee-rootless`, a SIF), as an Apptainer or Singularity instance that needs no root, subuid range or writable layer. Every service of the package (Puma, Sidekiq, Gitaly, PostgreSQL, Redis, nginx, GitLab's own SSH server) runs as you. If the login node cannot mount a SIF for an unprivileged user, the image is extracted once into `~/pw/software/containers/` and run from there | `apptainer`/`singularity` on the login node, 1.8 GB for the SIF |
| **Docker** | The official all-in-one image `gitlab/gitlab-ee:19.5.1-ee.0`, as root | Docker on the login node, directly or through `sudo`, 5 GB for the image |

Both need about 4 GB of free RAM for GitLab (8 GB recommended) and keep everything in
the **Run directory**. A run directory belongs to one runtime: Docker writes `config/`,
`data/` and `logs/` as root, Singularity writes everything as you, and each refuses the
other's directory. Under Singularity every file in the run directory is yours, so it
can live on any filesystem (local disk, NFS, Lustre, GPFS) and `rm -rf` removes it.
Hardened login nodes (a STIG image, FIPS mode, no FUSE mount of the SIF) work too, with
notices in the run's log.

## Requirements

- GitLab runs on the cluster's **login node**, never in a scheduler job, because the
  service outlives the run. Only CI jobs reach the compute nodes, through the SLURM
  runner.
- One of the two runtimes above on the login node.
- A platform with session subdomains (GitLab serves at the root of its address).
- For the SLURM runner: `sbatch`, `squeue`, `scancel` and `sacct` on the service host,
  with SLURM accounting enabled. Jacamar reads each job's final state from `sacct`, so
  the controller refuses the runner on a cluster without `AccountingStorageType`.

## Signing in

With the *Sign in with ACTIVATE* group filled in, users sign in with their ACTIVATE
account (below) and need nothing else. GitLab's `root` account is for administration.
Its password is the one in the form, or the one the workflow generated into
`<run directory>/.root_password` (mode 600) when the form left it empty. The root
password is applied only when the database is created; change it in GitLab afterwards.

### Sign in with ACTIVATE

GitLab's OpenID Connect provider is in every edition, so this needs no license.

1. **Pick the address, then register an application for it** (an organization admin
   does this once). An application is registered for one exact redirect URI, built
   from the GitLab address the form's **Subdomain** sets:
   `https://<subdomain>.<sessions domain>/users/auth/openid_connect/callback`. With the
   default subdomain on activate.parallel.works that is
   `https://gitlab-<user>.activate.pw/users/auth/openid_connect/callback`; other
   platforms have their own sessions domain.

   Turn on the *OIDC Applications* preview in your account settings, open
   Organization → Settings → Applications and add a **web** application with that
   redirect URI. You get the client ID at once and the client secret when you create
   one (shown a single time; an admin can reveal it again). The same through the API:

   ```bash
   pw api -X POST organizations/<org>/oidc/apps --input - <<'EOF'
   {"name": "GitLab", "kind": "web", "consent": "none", "subjectType": "username",
    "scopes": ["openid", "profile", "email"],
    "redirectUris": ["https://<subdomain>.<sessions domain>/users/auth/openid_connect/callback"],
    "postLogoutRedirectUris": ["https://<subdomain>.<sessions domain>/"]}
   EOF
   pw api -X POST organizations/<org>/oidc/apps/<clientId>/secrets
   ```

   Reserve the subdomain too, so nobody else takes it: `pw subdomains reserve <label>`.
2. **Launch** with the client ID and the client secret in the *Sign in with ACTIVATE*
   group. GitLab's login page gets an **ACTIVATE** button. The first sign-in creates
   the GitLab account (username = ACTIVATE username, email from the account). With
   **New users wait for approval** on, the account stays blocked until an administrator
   approves it under Admin → Users.
3. Open GitLab **in its own tab** (`https://<subdomain>.<sessions domain>/`). The
   sign-in does not complete inside the platform's embedded session view.

The provider is part of GitLab's configuration. A later run without a client ID
removes the button; the accounts it created stay.

## CI/CD runners

A runner is a process that takes jobs from GitLab and runs them **as the Linux user
that started it**. A runner Jane started runs every job as Jane, with Jane's files,
cluster account and SLURM allocations, no matter which GitLab account pushed the
commit. So the workflow never shares a runner between users: each user's runners only
take jobs from that user's own projects.

| Who | Mode | The runners serve | Runner files |
|---|---|---|---|
| **The owner**, who starts GitLab | *Start GitLab* | the group named in **Group of the runners** (`<username>-ci` by default) | `<run directory>/runner/` |
| **Every other user** of that GitLab | *Add my runners to a running GitLab* | a project or group of theirs | **Runner directory** (`${HOME}/gitlab-runner`) |

Both modes register the same two runners. They run on the service host out of the
user's runner files (configuration, builds, cache, `runner.log`), which only that user
can read. The runner tokens are stored there too, so a later start on the same
directory reuses the registration:

| Runner | Executor | Jobs | What runs where |
|---|---|---|---|
| **shell** (tag `shell`, takes untagged jobs) | GitLab's shell executor | any | the whole job on the service host |
| **SLURM** (tag `slurm`) | GitLab's custom executor with Jacamar CI | `tags: [slurm]` | `before_script` + `script` inside an `sbatch` job; sources, artifacts and `after_script` on the service host |

### The owner's runners

The owner's runners are **group runners**: they only take jobs from projects in the
group, so no project elsewhere in GitLab can run as the owner. Create your projects in
the group, or move them there (the project's Settings → General → Advanced).

The group is created on the first start, private. With *Sign in with ACTIVATE*
configured, the workflow makes the owner's GitLab account the group's Owner, creating
the account ahead of its first sign-in if needed. Without it, `root` owns the group.

Anyone who can push to a project in the group can run jobs as you. Share those
projects as carefully as your cluster account.

### Adding your runners to someone else's GitLab

You need the GitLab's session shared with you (the owner does that from the platform's
sessions page) and an account on the cluster it runs on. Then:

1. Sign in with ACTIVATE and create a project.
2. Create a personal access token: avatar → Edit profile → Access tokens → Add new
   token, pick **Legacy token** (not a fine-grained one), tick the `api` and
   `create_runner` scopes and set the expiry to a day. GitLab shows the token once;
   copy it. Keep the expiry short: the platform keeps form values in the run's record.
3. Launch this workflow with **Add my runners to a running GitLab** on the same cluster:

   | Field | Value |
   |---|---|
   | Service host | the cluster GitLab runs on |
   | GitLab address | the address in your browser, `https://<subdomain>.<sessions domain>` |
   | GitLab personal access token | the token from step 2 |
   | Project or group | the full path of your project, namespace included (`jane/hpc-pipeline`, not `hpc-pipeline`), or of your group (`team-a`): everything after the GitLab address in the browser. You must be a Maintainer of the project or an Owner of the group |
   | Register a shell runner / a SLURM runner | as you need |

The run registers the runners for that project or group, starts them as you and serves
a status page as its session: which runners are up, where jobs run, whether GitLab is
reachable, the runner log. The runners keep running until you delete that session. A
later start on the same runner directory needs no token.

Your jobs run as you. On a login node with a `pw` sign-in of its own they can call `pw`
directly; on a cloud cluster set `PW_API_KEY` as a masked CI/CD variable (below).

**How the runners reach GitLab.** The public address sits behind the platform's
sign-in, which runners cannot pass, so they connect to the loopback port GitLab listens
on. Every user of the login node shares that port, so the workflow checks who is on the
other end. It asks GitLab for its port, uid and host through the public address, which
only the owner's session answers for, and starts a small forwarder of its own. Every
connection from the runner, Jacamar or `git` goes through that forwarder, which checks
in `/proc/net/tcp` that the listening socket belongs to GitLab's uid (or to root, for a
port Docker publishes) before relaying a byte. If another user's process takes the
port over after GitLab stops, the connection is refused and no runner token, job token
or job variable reaches it. The status page then shows GitLab as unreachable; add the
runners again once it is back (a restarted GitLab listens on a new port).

### Writing the jobs

A SLURM job passes its `sbatch` options in the `SCHEDULER_PARAMETERS` variable,
including whatever the cluster requires of every job (account, partition, QoS). Leave
out `-o`, `-e`, `-J` and `--wait`: Jacamar sets those. Each job also needs the
`CI_JOB_JWT` id token that Jacamar reads; a `default:` block gives it to every job in
the project. Set a wall time, because GitLab's job timeout keeps counting while the
job waits in the queue.

Jacamar runs the stages that stay on the login node (sources, artifacts, cache) in a
login shell with a clean environment. The workflow links `gitlab-runner` into `~/bin`
so the login profile finds it. If your profile does not put `~/bin` on the PATH, the
run's log warns you, and artifacts of SLURM jobs stay on the cluster.

```yaml
default:
  id_tokens:
    CI_JOB_JWT:
      aud: $CI_SERVER_URL

hello-slurm:
  tags: [slurm]
  variables:
    SCHEDULER_PARAMETERS: "--nodes=1 --time=00:10:00"   # plus --account=..., --partition=... as the cluster requires
  script:
    - echo "SLURM job $SLURM_JOB_ID on $SLURM_NODELIST"
    - srun hostname
```

### Pipelines that call `pw`

A job on the shell runner can reach any resource in its user's account with the `pw`
CLI (`pw ssh <cluster> <command>`, `pw workflows run ...`). That needs a credential
that outlives the workflow run: the run's own key stops working when the run
completes, and the runner never gets it. On a cluster connected through the ACTIVATE
agent, the login node is already signed in as the runner's user. On a cloud cluster,
set **`PW_API_KEY`** as a masked CI/CD variable (the project's Settings → CI/CD →
Variables) holding one of your API keys (account settings → API keys). A group
variable covers every project in the group. Step 3 of the
[tutorial](tutorial/README.md) runs one job on several resources this way.

## Git from the command line

The endpoint serves GitLab behind the platform's sign-in, which `git` cannot pass, so
clones and pushes do not go through `https://<subdomain>.<sessions domain>`. They use
GitLab's ports on the service host instead:

- **From the cluster** (a terminal, JupyterLab or any session on it):
  `git clone http://localhost:<HTTP port>/<group>/<project>.git`. The HTTP port is the
  one `pw endpoints run` assigned; the run's log prints it, and `ss -ltnp` on the host
  shows who listens on it (nginx under Singularity, docker-proxy under Docker). Both
  runtimes bind the HTTP and SSH ports on the loopback interface of the service host
  only.
- **From your machine:** open a tunnel first, then clone through it:

  ```bash
  pw forward -L 2222:localhost:2222 <cluster>      # the form's SSH port
  git clone ssh://git@localhost:2222/<group>/<project>.git
  ```

  Add your public key to GitLab first (Profile → SSH Keys). The HTTP port works the same
  way with your GitLab password or a personal access token.

The runners talk to GitLab over the host's loopback as well, so pipelines need no
tunnel.

## License

| Image | What you get |
|---|---|
| `gitlab/gitlab-ee:<version>-ee.0` (default) | the Free tier without a license; Premium or Ultimate features with one |
| `gitlab/gitlab-ce:<version>-ce.0` | the MIT-licensed Community Edition; takes no license |

Paste a license key (the contents of a `.gitlab-license`: a Premium or Ultimate
subscription, or a trial from GitLab's site) into **GitLab license**. The workflow
applies it once and remembers it in the run directory (`.license-*` markers). Later
runs may leave the field empty; a different key replaces the current one. Sign in with
ACTIVATE and the runners need no license.

## Form

| Field | Default | Notes |
|---|---|---|
| What to start | Start GitLab | *Add my runners to a running GitLab* hides the GitLab and sign-in settings and shows the four runner fields below |
| Run container using | Singularity | See above |
| Subdomain | `gitlab-<username>` | Decides the address, the clone URLs and the OIDC redirect URI. Reserve it with `pw subdomains reserve <label>` |
| Run directory | `${HOME}/gitlab` | `config/`, `data/`, `logs/` (written by the container; under Singularity `data/.rootless/` also holds what the package writes into its install directory), `runner/` (yours), the generated secrets and, under Singularity, `work/` (the container's `/tmp`). One GitLab at a time, one runtime per directory; readable by you alone |
| GitLab image | `gitlab/gitlab-ee:19.5.1-ee.0` | Docker only. Change the tag one minor version at a time on an existing run directory (GitLab's upgrade path) |
| Root password | empty | Applied on the first start only; empty generates one into `<run directory>/.root_password` |
| SSH port | `2222` | Loopback port of GitLab's SSH on the service host, shown in GitLab's SSH clone URLs |
| GitLab license | empty | See above |
| GitLab address | | Runner mode: the GitLab's `https://...` address. On activate.hpc.mil it defaults to `https://gitlab.pw.hsp.mil` |
| GitLab personal access token | empty | Runner mode: scopes `api` and `create_runner`. Needed to register the runners, not to start registered ones again |
| Project or group | | Runner mode: the full path, namespace included, of the project or group whose pipelines the runners take |
| Runner directory | `${HOME}/gitlab-runner` | Runner mode: the runners' tokens, configuration, builds and cache |
| Group of the runners | `<username>-ci` | Start GitLab: the group whose projects the owner's runners serve |
| Register a shell runner | on | |
| Register a SLURM runner | off | Shown on SLURM clusters |
| Client ID / Client secret | empty | Sign in with ACTIVATE; both or neither |
| New users wait for approval | off | Shown with a client ID |

## Teardown

Delete the session from the platform's sessions page or with
`pw endpoints delete <name>`. The start script's cleanup stops GitLab: under
Singularity a `gitlab-ctl stop` inside the instance, then the instance itself
(`apptainer instance list` shows none left); under Docker a `docker rm -f`. The runner
session is killed either way. The run directory keeps everything. Under Singularity it
is all yours (`rm -rf`); what the Docker container wrote belongs to root
(`sudo rm -rf`). A SLURM CI job still running at teardown finishes on its own, but
nothing collects its result since its runner is gone; `scancel` it if it should not
finish.

Deleting a runner session (`gitlab-runners-<run slug>`) stops that user's runners and
forwarder; the runner directory keeps the registration. Other users' runners keep
running after GitLab's session is deleted. They refuse every connection until their
user deletes their session too, or GitLab comes back on the same port.

## Building the Singularity image

```bash
cd workflows/gitlab/gitlab-singularity
./build-container.sh        # the official gitlab/gitlab-ee image plus rootless/ (gitlab.def)
tools/oras/oras push ghcr.io/parallelworks/gitlab:19.5.1-ee-rootless gitlab-19.5.1-ee-rootless.sif
```

`rootless/` makes the package run as one unprivileged user from a read-only image.
`post.sh` (the build step) patches the few places that insist on root, replaces the
image's OpenSSH with GitLab's own `gitlab-sshd` and turns every path the package writes
under `/opt/gitlab` into a symlink into `data/.rootless/`. `init-rootless` is the
entrypoint. `passwd.in` and `group.in` are the account files the launcher binds, naming
the running uid `git` and every other account of the package. For a new GitLab
version: a new `From:` line in `gitlab.def`, a new `GITLAB_SIF_TAG` in `controller.sh`,
a new tag on the registry. `post.sh` fails the build when the package moved what it
patches. Keep the package public.
