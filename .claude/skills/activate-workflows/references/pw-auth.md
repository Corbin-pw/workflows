# `pw` inside a workflow: which credential it runs on

Read this when a workflow's scripts call `pw` or the platform API, and above all when
they keep doing so after the run completes.

## Where `pw` is signed in on its own

- **The user workspace and the login node of an existing or managed cluster**
  (resource `type: existing` or `managed-cluster`, connected through the ACTIVATE
  agent): `pw` is signed in as the user; the agent keeps the credential there (agent
  v7.102.0 or later). Verified 2026-10-26 from a run on an existing cluster (agent
  v7.127.0) and 2026-10-28 on a managed cluster and the workspace: `pw auth whoami`
  answers after `unset PW_API_KEY`.
- **A cloud cluster**: nothing is signed in (the same step there gets `no context
  configured; use 'pw auth'`). The user signs the CLI in on the login node (`pw auth`,
  again when that session expires) or the workflow is handed a key (below).

`pw auth --help` says the same: pre-authenticated for user workspaces and existing
clusters, authenticate for a cloud cluster or a local CLI. A `PW_API_KEY` environment
variable takes precedence over the saved credential.

## The run's key

The platform puts the run's `PW_API_KEY` into the environment of every step, on a
cluster login node and on the workspace alike, and a top-level `env:` block cannot
replace it: a value set there for `PW_API_KEY` is ignored (verified 2026-10-27). A
submitted script and the service it starts inherit the key (verified via
`/proc/<pid>/environ`), so a service can use it as the platform bearer with no org
secret. Keep it out of `inputs.sh` (preprocessing writes
`env | grep '^PW_' | grep -v 'PW_API_KEY'`) and read it from the runtime env.

`permissions: ['*']` decides what the key may do, not whether it is there: without it
the key still identifies the user (`pw auth whoami` answers) but a call beyond the
run's own sessions is refused (`pw clusters ls`, `pw endpoints list`, `pw workflows ls`:
`Unauthorized`; the docs: the run "will only be able to update any sessions it
creates"; verified 2026-10-27 on a cluster login node and on the workspace). The token
itself differs with the permission.

**It belongs to the run.** It is rejected as soon as the run ends (verified 2026-09-24):
a scheduler job or a service that inherited it keeps serving the endpoint it registered
(the tunnel runs on its own key), but every new call made with it afterwards, a `pw`
command or a request with it as the bearer, fails with `Authentication has expired`.
On `activate.hpc.mil` a key lasts at most 30 days in any case. A service that only
serves needs nothing more.

## A service that calls `pw` after the run completes

A collector, a page that launches runs, a teardown: it needs a credential that outlives
the run. The platform injects `PW_API_KEY` itself, so the job script, not the YAML,
swaps it:

1. **Existing cluster**: drop the inherited key before calling `pw`; the login node's
   own sign-in takes over, and nothing has to be managed or rotated:
   ```bash
   unset PW_API_KEY
   ```
2. **Cloud cluster**: a personal API key (Account > Authentication > API keys),
   exported as `PW_API_KEY` at the top of the job script and replaced before it
   expires: only new `pw` invocations read it, a running tunnel is not affected.
   Setup 1 works there too once the user has run `pw auth` on the login node.

`env -u PW_API_KEY pw auth whoami` tells at run time whether the node has a sign-in of
its own, `PW_API_KEY=<key> pw auth whoami` whether a given key works;
`workflows/hpc_status/app/start-template.sh` tries both and warns when neither holds.

## A key the user hands the workflow

A `password` input, carried under another name in the top-level `env:` block and read
from the runtime env (`workflows/probe/yamls/general.yaml`, `PROBE_API_KEY`). Show it
only where the host has no sign-in of its own: hide and ignore it for `existing`,
`managed-cluster` and the workspace (the resource fields,
[activate-platform.md](activate-platform.md) §2), and before anything is submitted
check the key given with `PW_API_KEY=<key> pw auth whoami`, else the host's sign-in
with `env -u PW_API_KEY pw auth whoami`, else fail the run
(`workflows/probe/app/credential.sh`); the start script then exports the key or unsets
the run's. An app
that needs the key as a string in its own config takes it on every cluster type
(`workflows/librechat`, `ACTIVATE_API_KEY`: checked with `pw auth whoami` before the
controller writes it into LibreChat's `.env`). Keep `set -x` off around it, or the
trace prints it; the platform keeps form values, password inputs included, in plain
text in the run's record (`pw workflows runs view`, verified 2026-10-27). A test
passes it from an environment variable (`_test.secrets`, `tools/tests/README.md`): a
key never sits in a test file or anywhere else in the repo.

A key handed to a **service that other users drive** (a CI runner, a job queue) lets
every one of them act as the key's owner: `workflows/gitlab` used to hand the owner's
key to the CI runner and stopped (2026-11-03); the runner starts with `env -u
PW_API_KEY`, each user runs runners of their own (the workflow's runner mode), and a
pipeline that calls `pw` sets `PW_API_KEY` as a masked CI/CD variable of its project.
