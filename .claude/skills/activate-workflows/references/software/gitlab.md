# GitLab (Linux package image, as the user under Apptainer or as root in Docker) behind an endpoint, with CI runners

What building `workflows/gitlab` taught (2026-10-28 to 11-03, GitLab 19.5.1-ee, gitlab-runner
19.5.1, Jacamar CI 0.31.0; Docker through `sudo` on a lab node and two cloud clusters,
apptainer 1.5.5 on a standard cloud image, singularity-ce 4.5.1 on a STIG-hardened one,
apptainer 1.5.3 on an HPCMP system with a Lustre home). The endpoint mechanics are [../activate-platform.md](../activate-platform.md)
§10, the OIDC recipe [../oidc-sign-in.md](../oidc-sign-in.md); this file is what GitLab
adds to them. The two runtimes share `lib/` (controller checks and runner tools, the
start template's first half, the launcher's GitLab logic); each runtime's files only
start and stop the container and define `gitlab_exec`, `gitlab_alive` and `gitlab_logs`.

## Running it

- **The image needs root, not necessarily Docker.** The Linux package (`gitlab/gitlab-ee`,
  `gitlab/gitlab-ce`) runs as root with runit as PID 1 and its services as eight accounts
  (`git` 998, `gitlab-www`, `gitlab-psql`, ...), bundling Puma, Sidekiq, Gitaly,
  PostgreSQL, Redis and nginx; the image is 4.7 GB, the SIF 1.8 GB. Two runtimes:
  - **Docker** (`gitlab-docker/`): the `openproject-docker` pattern (`docker run -d` in a
    launcher under `pw endpoints run`, `docker logs -f & wait` as the foreground,
    `cancel.sh` with `docker rm -f`, `flock` on the run directory; on a FIPS-mode host
    `-v <file holding 0>:/proc/sys/crypto/fips_enabled:ro`, see the Singularity bullet).
    A cold start answered `/users/sign_in` in about 2.5 minutes on a 20-core node; later
    starts take about 2.
  - **Singularity** (`gitlab-singularity/`, SIF `ghcr.io/parallelworks/gitlab:19.5.1-ee-rootless`
    built from `gitlab.def` + `rootless/`): the **single-user image** of
    [singularity-sif-containers.md](singularity-sif-containers.md), "An image that needs
    root, rebuilt to run as the user", whose worked example this workflow is. Every
    service runs as the user from a read-only image, so the run directory can sit on any
    filesystem and the node needs no subuid range or writable layer. What is GitLab's
    own: the entrypoint
    `/assets/init-rootless`; `rootless/gitlab.rb`, evaluated in place before
    `GITLAB_OMNIBUS_CONFIG`, names `git` as the account of every service and enables
    `gitlab_sshd`, which takes the form's port through `gitlab_sshd['listen_address']`;
    `GITLAB_OMNIBUS_CONFIG` passed as `APPTAINERENV_`/`SINGULARITYENV_` with `$`,
    backticks and backslashes escaped (pitfalls, "Passing secrets and values with spaces
    into Apptainer"); `GITLAB_SKIP_TAIL_LOGS=true` so the package's logs stay in `logs/`;
    `gitlab-ctl stop` as the stop command in `cancel.sh`; and, because the container
    shares the host's network, `nginx['listen_port'] = $PORT` with
    `nginx['listen_addresses'] = ['127.0.0.1']` and every other fixed loopback listener of
    the package moved or turned off so two GitLabs can share a node: `puma['port']`
    (workhorse uses puma's unix socket), `gitlab_workhorse['prometheus_listen_addr']`,
    `gitaly['configuration'] = { prometheus_listen_addr: ... }`,
    `gitlab_sshd['metrics_address']`, `sidekiq['metrics_enabled']`,
    `sidekiq['health_checks_enabled']`, `nginx['status']['enable']` (port 8060 on every
    interface) and `gitlab_kas['enable']`; PostgreSQL and Redis listen on unix sockets
    only. A first start answers `/users/sign_in` about 5 minutes after the instance
    starts on a 16-core node. The root password must pass GitLab's weak-password check
    (a generated one does).
  - **Login node only, both runtimes** (2026-10-29): the YAMLs have no scheduler section
    and call the submitter with `scheduler: false`. A service that outlives the run has
    no place in an allocation, and on the cloud clusters a compute node has no subuid
    range and mounts home over NFS, where the namespace's `chown` is refused (the start
    template still checks both and says so). The CI jobs are what reach the compute
    nodes.
- **Configuration in one env line.** `GITLAB_OMNIBUS_CONFIG` is Ruby evaluated after
  `/etc/gitlab/gitlab.rb` at every start; a docker `--env-file` takes no newlines, so
  join the statements with `; `. It must contain `external_url 'https://<host>'`,
  `nginx['listen_port'] = 80`, `nginx['listen_https'] = false` and
  `letsencrypt['enable'] = false`, or the bundled nginx wants certificates. The config
  volume (`/etc/gitlab`) is written as root, so anything the host's user must rewrite
  on every start (the nginx snippet below) is a separate bind mount of a file in the
  run's own job dir, not a file in that volume.
- **Memory.** `prometheus_monitoring['enable'] = false`, `puma['worker_processes'] = 2`
  and `sidekiq['concurrency'] = 10` keep a demo instance around 3 GB; the docs' floor is
  4 GB RAM for real use, 8 GB recommended.
- **Probe `/users/sign_in` with the public `Host`** from inside the node: it answers 200
  only once Puma serves *and* the forwarded-protocol fix works (302 to itself
  otherwise); `/-/readiness` says nothing about the latter.

## The session proxy and the sign-in (both verified)

- **Forwarded headers.** The platform proxy sends `X-Forwarded-Proto: http`; GitLab
  with an https `external_url` then redirects every page to itself and drops its
  Secure session cookie. The bundled nginx fixes it on its own, no extra proxy:
  `nginx['proxy_set_headers'] = { 'Host' => '$http_host_with_default', 'X-Real-IP' =>
  '$remote_addr', 'X-Forwarded-For' => '$proxy_add_x_forwarded_for',
  'X-Forwarded-Proto' => 'https', 'X-Forwarded-Ssl' => 'on', 'Upgrade' =>
  '$http_upgrade', 'Connection' => '$connection_upgrade' }`.
- **The hop to the identity provider.** The proxy rewrites a redirect to another host
  onto the session's host, so the `302` that `POST /users/auth/openid_connect` answers
  (to `https://<platform>/api/oidc/authorize?...`) must become a 200 hop page. The
  bundled nginx can do it for that one route: `nginx['custom_gitlab_server_config'] =
  'include /etc/gitlab/activate/nginx.conf;'` is inserted at the end of the server
  block (rendered at `data/nginx/conf/service_conf/gitlab-rails.conf`), and the
  included file defines `location = /users/auth/openid_connect { proxy_pass
  http://gitlab-workhorse; <the proxy_set_header lines above>; proxy_intercept_errors
  on; error_page 301 302 303 307 308 = @activate_hop; }` plus the `@activate_hop`
  named location from the OpenProject recipe (`return 200 '<meta http-equiv="refresh"
  ...$upstream_http_location>'`, same-host targets re-issued as `302`, the upstream's
  `Set-Cookie` re-added). `gitlab-workhorse` is the upstream's name and
  `$http_host_with_default` is set in the server block, so both are available to the
  snippet. Verified with the curl flow of oidc-sign-in.md: the POST came back 200 with
  the authorize URL carrying `client_id`, `code_challenge_method=S256` and the
  registered `redirect_uri`.
- **The provider.** `gitlab_rails['omniauth_providers'] = [{ name: 'openid_connect',
  label: 'ACTIVATE', args: { name: 'openid_connect', scope: ['openid', 'profile',
  'email'], response_type: 'code', issuer: 'https://<platform>/api/oidc', discovery:
  false, uid_field: 'preferred_username', pkce: true, client_options: { identifier,
  secret, redirect_uri: 'https://<host>/users/auth/openid_connect/callback',
  authorization_endpoint, token_endpoint, userinfo_endpoint, jwks_uri:
  'https://<platform>/api/platform/keys', end_session_endpoint } } }]`, with
  `omniauth_allow_single_sign_on = ['openid_connect']`, `omniauth_auto_link_user =
  ['openid_connect']` and `omniauth_block_auto_created_users` as the form says. The
  callback path is fixed by GitLab, so the application is registered for exactly
  `https://<subdomain>.<sessions domain>/users/auth/openid_connect/callback`. OIDC
  sign-in is in the Free tier; no license needed.
- **git cannot clone through the endpoint**: the proxy demands the platform's login or
  bearer key and strips `Authorization` before GitLab sees it. Clones go to the
  container's published loopback ports instead (`-p 127.0.0.1:${PORT}:80`,
  `-p 127.0.0.1:<ssh port>:22`): from the cluster `http://localhost:<port>`, from a
  laptop through `pw forward -L`. `gitlab_rails['gitlab_shell_ssh_port']` puts the
  SSH port into the clone URLs GitLab shows.

## Automating the first start (verified)

- **A root API token without a password**: `docker exec <c> gitlab-rails runner "t =
  User.find_by_username('root').personal_access_tokens.create!(scopes: ['api',
  'create_runner'], name: '...', expires_at: 1.day.from_now); puts t.token"` prints a
  usable token in about 40 s (Rails boot); `DELETE /api/v4/personal_access_tokens/self`
  revokes it (204). `gitlab_rails['initial_root_password']` applies only when the
  database is created; a user-readable sign that it exists is `data/postgresql/data`
  (`data/postgresql` is `2775`).
- **Runners through the API**: `POST /api/v4/user/runners` with `runner_type=
  group_type&group_id=N` (or `project_type&project_id=N`), `tag_list`, `run_untagged`
  returns the `glrt-` token (201); keep it (`POST /api/v4/runners/verify` with `token`
  says 200 while it is valid) and rewrite `config.toml` on every start because the
  GitLab port changes with the endpoint. Set `url` **and** `clone_url` to
  `http://127.0.0.1:<port>`: the job payload otherwise tells the runner to clone from
  `external_url`, which the proxy blocks. The runner runs as the user (`gitlab-runner
  run --config ... --working-directory ...`, "Running in user-mode" is fine) under
  `setsid`, outside the endpoint's process tree, and `cancel.sh` kills its session.
- **A success body can carry a secret** (the runner token): print `message` from an
  error body, never the body of a call that may have succeeded.
- **The run must not complete before this setup is done.** The platform's probe of
  `/users/sign_in` would see 200 as soon as Puma serves, so the nginx snippet gates
  that one route (503 until the launcher touches `ready`, bypassed by the launcher's
  own `X-Activate-Probe` header); the general entry is in pitfalls.md ("Setup that
  must run after the service answers gates the probed route"). The gate directory is
  `chmod 755`: nginx's workers test the marker as an unprivileged user.
- **Two GitLabs on one host** (a kept demo instance beside a test) need distinct run
  directories, subdomains and SSH ports; the container carries
  `--label activate.rundir=<run directory>` so a test's leftover check counts only its
  own (`docker ps -aq --filter label=activate.rundir=$HOME/<dir>`).

## Jacamar CI (the SLURM runner)

- Prebuilt static binaries live in gitlab.com's **generic package registry**, not in
  the release assets: `https://gitlab.com/api/v4/projects/ecp-ci%2Fjacamar-ci/
  packages/generic/jacamar-ci/<ver>/jacamar-ci-<ver>.ubi9.amd64.tar.gz` holds
  `jacamar` and `jacamar-auth` at its root (`checksums.sha256.txt` beside it; the
  controller pins the tarball's sha256). The RPMs there need root to install; a Go
  build from source also works (`make build` with Go 1.20+, `libseccomp` headers).
- **Plain `jacamar` refuses to run without `--no-auth`** ("Jacamar requires --no-auth
  in order to support execution requirements", the job fails in `prepare_executor`):
  every stage's args start with it, `["--no-auth", "config", "--configuration",
  "<jacamar.toml>"]`, `["--no-auth", "prepare"]`, `["--no-auth", "run"]`,
  `["--no-auth", "cleanup", "--configuration", "<jacamar.toml>"]`. `jacamar-auth` is
  the privileged wrapper (setuid or sudo downscoping) for a shared runner; an
  unprivileged per-user runner does not need it.
- `jacamar.toml`: `[general] executor = "slurm"`, `data_dir = <a directory the user
  owns, mode 0700 enforced>` and **`gitlab_server = "http://127.0.0.1:<port>"`**:
  Jacamar verifies the job's id token against GitLab's JWKS, fetched by default from
  the `CI_SERVER_URL` of the job response, the public endpoint, where the proxy
  answers the sign-in page (`unable to retrieve key from JWKS endpoint: failed to
  decode response, invalid character '<'`). Every job also needs the token itself,
  or `prepare_executor` fails with "No id_token found on CI_JOB_JWT variable": a
  `default: id_tokens: CI_JOB_JWT: aud: $CI_SERVER_URL` block at the top of
  `.gitlab-ci.yml` covers the project (verified: GitLab 19.5 accepts the variable as
  `aud`, Jacamar accepted the token). A job's `SCHEDULER_PARAMETERS` variable carries
  the `sbatch` options (`--nodes=1 --time=00:10:00`); `-o`, `-e`, `-J` and `--wait`
  are Jacamar's. Only `before_script` + `script` run in the batch job (`sbatch
  --wait`, output tailed from `slurm-ci-<job>.out`); sources, artifacts and
  `after_script` run on the runner's host. The options a cluster requires (account,
  partition, QoS) go into each job's `SCHEDULER_PARAMETERS`; the workflow sets no
  cluster-wide `[batch] default_args` in `jacamar.toml`.
- **A runner runs every job as the Linux user it runs as**, whichever GitLab account
  pushed, so the workflow never shares a runner between users. The owner's runners are
  **group runners** of a private group the owner owns (`POST /user/runners` with
  `runner_type=group_type&group_id=N`; the group from `POST /groups`; with OIDC the
  owner's account is created ahead of its first sign-in, `POST /users ...
  provider=openid_connect&extern_uid=<PW_USER>`, and made Owner, `POST
  /groups/:id/members access_level=50`, `PUT` on 409). Every other user adds runners of
  their own through the workflow's **runner mode** on the same login node
  (`lib/runner-start-template.sh`): project or group runners of a full path of theirs
  (`GET /projects/:path`, then `GET /groups/:path`), registered with their personal
  access token (`api` + `create_runner`) and started as them from their own directory.
  A stored runner is reused only while `POST /runners/verify` answers 200 *and* `GET
  /runners/:id` shows the scope this run wants (`runner_type`, `groups[].id` or
  `projects[].id`); otherwise it is deleted and registered again. The runner starts
  with `env -u PW_API_KEY`; a pipeline that calls `pw` sets `PW_API_KEY` as a masked
  CI/CD variable (pw-auth.md). Verified 2026-11-03 on a STIG login node (a pipeline of
  the group ran on the added runners: a shell job and a SLURM job through Jacamar) and
  by a second account on a shared cloud cluster of activate.hpc.mil (its runners
  registered as it through the shared session).
- **Finding another user's GitLab on the login node, safely** (verified 2026-11-03): the
  runner must use the loopback port (the proxy strips `Authorization`), which every
  user of the node shares, so (1) the GitLab's nginx snippet answers `GET
  /-/activate/host` with `{"port", "uid", "host"}` behind the platform's sign-in, and
  the runner-mode run reads it through the public address with its own `PW_API_KEY`
  (the session must be shared with that user; the proxy's routing of the subdomain
  vouches for the answer); (2) `/proc/net/tcp` is world-readable and names the uid of
  every socket, so `lib/runner-service.py listener-uid <port>` checks who holds the
  port before anything is sent; (3) the runner, Jacamar and git reach GitLab through a
  forwarder of the run (`runner-service.py forward`) that opens each connection to the
  port and relays it only once the accepted socket at the other end (`local = port,
  remote = our ephemeral port` in `/proc/net/tcp`) belongs to that uid or to root
  (docker-proxy); a process that takes the port over after GitLab stops is refused
  before a byte is sent. The status page (`runner-service.py status`, the endpoint)
  shows the listener's state the same way. Python 3.6 is enough for it.
- **`/proc/net/tcp` columns:** `sl local_address rem_address st ... uid ... inode`;
  addresses are little-endian hex (`0100007F:1F90` is 127.0.0.1:8080), state `0A` is
  LISTEN, `01` ESTABLISHED; a socket in the accept queue already shows the listener's uid.
- **The runner tools in a shared install directory** (the HSP project directory): a
  tool another user installed is used as is when executable, the installer runs
  `chmod a+rX` on it (a hardened node's umask is 0027), and a user who can write
  neither installs into `~/pw/software`; the start scripts look in both places
  (`lib/runner-tools.sh`, `runners_find_tool`).
- **Jacamar's host-side stages run as `env -i /bin/bash --login` scripts** (its docs, and
  verified 2026-10-29): the runner's environment never reaches them, and the artifact and
  cache stages look `gitlab-runner` up by name, so a runner binary outside the login
  shell's PATH gives "Missing gitlab-runner. Uploading artifacts is disabled." (the job
  still succeeds, the artifacts never arrive, a `needs:` consumer finds nothing). A
  symlink in `~/bin` (on the PATH of the default Rocky and Ubuntu profiles) is the fix;
  `user_bash_env = ["PATH=<dir>:$PATH"]` in `jacamar.toml` does not: the value goes to
  `env -i` as is, `$PATH` stays literal and the job dies with `bash: No such file or
  directory`. The launcher creates the link and probes a login shell for it.
- **Jacamar needs SLURM accounting.** After the batch job ends it reads the state
  with `sacct`; on a cluster without `AccountingStorageType` the job's script runs
  to the end and the CI job still fails with `unable to obtained output via sacct:
  Slurm accounting storage is disabled` (a lab box without slurmdbd, 2026-10-28). No
  option turns this off; the controller refuses the SLURM runner there. On a cloud
  cluster with `accounting_storage/slurmdbd` the whole path ran through the workflow:
  the demo pipeline's `hello-slurm` job became SLURM job `ci-4_<id>` on a compute node
  that SLURM powered on for it, Jacamar read `COMPLETED` from `sacct`, the job succeeded;
  the pipeline took about 220 s with the node boot. A test's teardown right after the run
  completes aborts a pipeline still running (`Job failed: aborted: terminated` in
  `runner.log`), which is the test, not the runner.
