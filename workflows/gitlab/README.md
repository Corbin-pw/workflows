# GitLab

Runs a self-hosted [GitLab](https://about.gitlab.com/) (repositories, merge requests,
issues, CI/CD) on a cluster's login node, from the official image under Singularity or
Docker, and serves it as a `pw` endpoint on a fixed subdomain. Users can sign in with
their ACTIVATE account, and the workflow registers CI/CD runners that run pipelines on
the cluster: on the login node, and through the SLURM scheduler with
[Jacamar CI](https://gitlab.com/ecp-ci/jacamar-ci). New to GitLab? The
[tutorial](tutorial/README.md) takes you from the launch form to pipelines that run on
the login node, on your other ACTIVATE resources and on the compute nodes, in about 45
minutes.

```
form ──► preprocessing ──► start script ──► GitLab answers, ──► https://<subdomain>.<sessions domain>/
         (checks, runner    (container,     runners registered,   the run completes; GitLab and its
          tools)             runners)       demo project created  runners run until the session is deleted
```

The first start of a run directory takes three to six minutes (GitLab configures
itself and creates its database); later starts two to four. The run completes once the
sign-in page answers and the runners are registered (until then the page answers 503
to the platform's probe); GitLab and its runners then run until the session is deleted.

## Two ways to run it

| Run container using | What runs | Needs |
|---|---|---|
| **Singularity** (default) | The official image rebuilt to run as **one unprivileged user** (`ghcr.io/parallelworks/gitlab:19.5.1-ee-rootless`, a SIF): an Apptainer or Singularity instance that needs no root, subuid range or writable layer, in which every service of the package (Puma, Sidekiq, Gitaly, PostgreSQL, Redis, nginx, GitLab's own SSH server) runs as you. A login node that cannot mount a SIF for an unprivileged user gets the image extracted once into `~/pw/software/containers/` and runs that directory | `apptainer`/`singularity` on the login node, 1.8 GB for the SIF |
| **Docker** | The official all-in-one image `gitlab/gitlab-ee:19.5.1-ee.0`, as root | Docker on the login node, directly or through `sudo`, 5 GB for the image |

Both need about 4 GB of RAM free for GitLab (8 GB recommended) and keep everything in the
**Run directory**. A run directory belongs to one runtime: Docker writes its `config/`,
`data/` and `logs/` as root, Singularity writes everything as you, and each runtime
refuses the other's directory. Under Singularity nothing in the run directory belongs to
another id, so it can live on any filesystem (a local disk, NFS, Lustre, GPFS: the home
of an HPC system) and `rm -rf` removes it. Hardened login nodes (a STIG image, FIPS mode,
no FUSE mount of the SIF) are handled with notices in the run's log.

## Requirements

- GitLab runs on the cluster's **login node**, never in a scheduler job: the service
  outlives the run. The CI jobs are what reach the compute nodes (the SLURM runner).
- One of the two runtimes above on the login node.
- A platform with session subdomains (GitLab serves at the root of its address).
- For the SLURM runner: `sbatch`, `squeue`, `scancel` and `sacct` on the service host, and
  SLURM accounting on (Jacamar reads every job's final state from `sacct`; the
  controller refuses the runner on a cluster without `AccountingStorageType`).

## Signing in

With the *Sign in with ACTIVATE* group filled, users sign in with their ACTIVATE account
(below) and need nothing else. GitLab's `root` account is for administration: its
password is the form's, or the one the workflow generated into
`<run directory>/.root_password` (mode 600) when the form left it empty. The root
password only applies when the database is created; change it in GitLab afterwards.

### Sign in with ACTIVATE

GitLab's OpenID Connect provider is in every edition, so this needs no license.

1. **Pick the address, then register an application for it** (organization admin,
   once). An application is registered for one exact redirect URI, which is built from
   the GitLab address the form's **Subdomain** decides:
   `https://<subdomain>.<sessions domain>/users/auth/openid_connect/callback`. With the
   default subdomain on activate.parallel.works that is
   `https://gitlab-<user>.activate.pw/users/auth/openid_connect/callback`; another
   platform has its own sessions domain.

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
   group. GitLab's login page gets an **ACTIVATE** button; a first sign-in creates the
   GitLab account (username = ACTIVATE username, email from the account). With **New
   users wait for approval** on, such an account stays blocked until an administrator
   approves it under Admin → Users.
3. Open GitLab **in its own tab** (`https://<subdomain>.<sessions domain>/`). Inside the
   platform's embedded session view the sign-in cannot complete.

The provider is part of GitLab's configuration: a later run without a client ID removes
the button, and the accounts it created stay.

## CI/CD runners

The workflow registers instance runners with the GitLab it started and runs them on
the service host **as the user who launched the workflow**, from
`<run directory>/runner/` (configuration, builds, cache, `runner.log`). Every CI job
runs as that user, on that user's cluster account and with that user's `pw` sign-in,
whichever GitLab account pushed the commit or started the pipeline: share the GitLab
only with people you would hand your cluster account to. The runners' tokens are kept
in the run directory too, so a later run on the same run directory finds them again.

| Runner | Executor | Jobs | What runs where |
|---|---|---|---|
| **shell** (tag `shell`, takes untagged jobs) | GitLab's shell executor | any | the whole job on the service host, with `pw` signed in (below) |
| **SLURM** (tag `slurm`) | GitLab's custom executor with Jacamar CI | `tags: [slurm]` | `before_script` + `script` inside an `sbatch` job; sources, artifacts and `after_script` on the service host |

A SLURM job passes its `sbatch` options in the `SCHEDULER_PARAMETERS` variable, the
ones the cluster requires of every job (an account, a partition, a QoS) included (`-o`,
`-e`, `-J` and `--wait` are Jacamar's), and must carry the `CI_JOB_JWT` id token Jacamar
reads, which a `default:` block gives every job of the project. Set a wall time:
GitLab's job timeout keeps counting while the job waits in the queue. Jacamar runs the
stages it keeps on the login node (sources, artifacts, cache) in a login shell with a
clean environment, so the workflow links `gitlab-runner` into `~/bin`, which the login
profile puts on the PATH; a profile that does not gets a warning in the run's log, and
artifacts of SLURM jobs then stay on the cluster.

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

A job of the shell runner can reach any resource of the launching user's account with
the `pw` CLI (`pw ssh <cluster> <command>`, `pw workflows run ...`), which needs a
credential that outlives the run: the run's own key stops working when the run
completes. On a cloud cluster give the workflow an **ACTIVATE API key** (account
settings, API keys): the runner hands it to every job as `PW_API_KEY`. On a cluster
connected through the ACTIVATE agent the login node is signed in already and the field
is not shown. The run's log says which credential the pipelines got, or that they got
none, in which case a project can still set `PW_API_KEY` as a CI/CD variable of its
own. Launch again with a new key before the old one expires. Step 3 of the
[tutorial](tutorial/README.md) runs one job on several resources this way.

## Git from the command line

The endpoint serves GitLab's pages behind the platform's sign-in, which `git` cannot
pass, so clones and pushes do not go through `https://<subdomain>.<sessions domain>`.
They go to GitLab's ports on the service host instead:

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

Paste a license key (`.gitlab-license` contents: a Premium or Ultimate subscription, or
a trial from GitLab's site) into **GitLab license**; the workflow applies it once and
remembers it in the run directory (`.license-*` markers). Later runs may leave the field
empty; a different key replaces the current one. Sign in with ACTIVATE and the runners
need no license.

## Form

| Field | Default | Notes |
|---|---|---|
| Run container using | Singularity | See above |
| Subdomain | `gitlab-<username>` | Decides the address, the clone URLs and the OIDC redirect URI. Reserve it with `pw subdomains reserve <label>` |
| Run directory | `${HOME}/gitlab` | `config/`, `data/`, `logs/` (written by the container; under Singularity `data/.rootless/` also holds what the package writes into its install directory), `runner/` (yours), the generated secrets and, under Singularity, `work/` (the container's `/tmp`). One GitLab at a time, one runtime per directory |
| GitLab image | `gitlab/gitlab-ee:19.5.1-ee.0` | Docker only. Change the tag one minor version at a time on an existing run directory (GitLab's upgrade path) |
| Root password | empty | Applied on the first start only; empty generates one into `<run directory>/.root_password` |
| SSH port | `2222` | Loopback port of GitLab's SSH on the service host, shown in GitLab's SSH clone URLs |
| GitLab license | empty | See above |
| Register a shell runner | on | |
| Register a SLURM runner | off | Shown on SLURM clusters |
| ACTIVATE API key | empty | Shown on cloud clusters; what pipelines run `pw` with after the run completes |
| Client ID / Client secret | empty | Sign in with ACTIVATE; both or neither |
| New users wait for approval | off | Shown with a client ID |

## Teardown

Deleting the session (the platform's sessions page, or `pw endpoints delete <name>`)
stops GitLab and the runners through the start script's cleanup: under Singularity a
`gitlab-ctl stop` inside the instance and then the instance itself (`apptainer instance
list` shows none left), under Docker a `docker rm -f`; the runner's session is killed
either way. The run directory keeps everything. Under Singularity it is all yours (`rm -rf`); what
the Docker container wrote belongs to root (`sudo rm -rf`). A CI job that is running in
SLURM at teardown finishes on its own (its runner is gone, so nothing collects its
result); `scancel` it if it should not.

## Building the Singularity image

```bash
cd workflows/gitlab/gitlab-singularity
./build-container.sh        # the official gitlab/gitlab-ee image plus rootless/ (gitlab.def)
tools/oras/oras push ghcr.io/parallelworks/gitlab:19.5.1-ee-rootless gitlab-19.5.1-ee-rootless.sif
```

`rootless/` makes the package run as one unprivileged user from a read-only image:
`post.sh` (the build step) patches the few places that insist on root, replaces the
image's OpenSSH with GitLab's own `gitlab-sshd` and turns every path the package writes
under `/opt/gitlab` into a symlink into `data/.rootless/`; `init-rootless` is the
entrypoint; `passwd.in` and `group.in` are the account files the launcher binds, naming
the running uid `git` and every other account of the package. New GitLab version: a new
`From:` line in `gitlab.def`, a new `GITLAB_SIF_TAG` in `controller.sh`, a new tag on
the registry; `post.sh` fails the build when the package moved what it patches. Keep
the package public.
