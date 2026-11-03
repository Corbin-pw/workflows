# Pitfalls and lessons from real runs

> The surprises real runs taught, each with the date it was verified. This file is
> the **memory** of the skill: [SKILL.md](../SKILL.md) is the process and
> [activate-platform.md](activate-platform.md) the platform facts. **When a run
> misbehaves, search this file for the symptom text before debugging from scratch**,
> and append what you learn under the matching section (SKILL.md Step 5).
>
> "Step N" means SKILL.md's step N; "reference §N" means section N of
> [activate-platform.md](activate-platform.md). Lessons about one piece of software
> (OpenFOAM, Dakota, ParaView, conda environments, Singularity/SIF images, MPI benchmarks,
> dask-jobqueue, PhysicsNeMo, PostgreSQL, Pydio Cells, File Browser, Design Explorer, Grafana +
> Prometheus) live
> in [software/](software/), one file per tool — grep both when a symptom is unclear.
>
> Sections: validation · inputs and expressions · jobs, outputs, matrix and retries ·
> resources, nodes and filesystems · `script_submitter` and scheduler jobs · endpoints and
> the service · `pw` CLI, auth and remote shells · code delivery and tests · shell
> scripting · software, sites and figures.

## Validation: `--dry-run`, variants and YAML parsing

- **Always `--dry-run`** before a real run; it catches schema/YAML problems cheaply.
- **`--dry-run` is necessary but NOT sufficient.** It only validates the YAML and
  required subworkflow inputs.
  "Tested end-to-end" (Step 3/4) means a real run, the endpoint online in
  `pw endpoints list`, exercising the *live* service, and debugging from `~/pw/jobs`. Don't
  call a workflow tested on a dry-run alone.
- **`Could not parse subworkflow` on `--dry-run`:** a non-optional subworkflow input
  with no default is missing from your `with:` block; the message never names it.
  Hidden+ignored inputs don't count — compare your block against the fields the
  subworkflow's form shows for the values you pass. A `script_submitter` call that
  leaves out `define_cleanup_script` fails this way on every variant: the flag's
  `default: false` does not reach `cleanup_script_path`'s `hidden:` test, so the path
  counts as required. Pass `define_cleanup_script: false` explicitly (verified
  2026-10-20; four `hsp` callers broke when the `hsp` submitter declared the flag).
- **Wrong deployment variant / mismatched resource form:** `general`'s slurm/pbs
  fields passed to an `emed`/`noaa`/`hsp` subworkflow are NOT rejected by `--dry-run`
  (unknown fields pass silently; verified 2026-09-16), so the mismatch surfaces only
  at run time. Match the variant to the host and copy its variant YAML form.
- **A plain-scalar `tooltip:` with a `: ` inside it is invalid YAML** (`mapping values are
  not allowed here`); the platform reports only `Invalid YAML`, so parse the file locally
  (`python3 -c "import yaml; yaml.safe_load(open(f))"`, the system python has PyYAML on
  the cloud cluster) before blaming the schema. Use a `|` block for any prose tooltip.
- **Input group named `env` + a top-level `env:` block** referencing `${{ inputs.env.* }}`
  → `Expression Parser Error: max recursion exceeded`, failing **both `--dry-run` and
  `pw workflows run`** (the web UI may still submit). Rename the group (e.g. `env_vars`).

## Inputs and expressions

- **A shown input without `label:` renders as its key name capitalized**
  (`Scheduler_directives`; verified 2026-10-19 on activate.parallel.works). `description:`
  is always visible under the label, `tooltip:` only behind the ?, so the sentence a user
  must read goes in the description (AGENTS.md, "Form text").
- **An empty group item is default-filled** (verified 2026-09-24): a hidden input sent as
  `"render_settings": {"name": ""}` reached the workflow as its default, like a top-level
  input; only a **list-template** field keeps `""` (the list-template entry below). Reruns built from a past
  run's INPUTS tab send `""` for every hidden field, so this is the normal path. Still build
  a name several jobs must agree on **once**, published as a preprocessing output
  (`workflows/burst-render-demo`). Corollary (2026-10-07, `workflows/benchmarks`): a
  failure-path test cannot reach an "input is empty" check by sending `""` for an input
  that has a default; send a value the form's `min`/`max` would forbid instead
  (`ntasks_per_node: 0`), which the API passes through unchanged.
- **Nested input groups pass through `with:` as nested maps** (`cluster: {scheduler: …,
  slurm: {…}}` beside the top-level `resource: ${{ inputs.resource }}` into
  `workflows/openfoam-naca/yamls/general.yaml`; dry-run and live run, 2026-10-01, when the
  `compute-clusters` item still sat inside the group and passed through the same way).
  Dotted keys (`cluster.scheduler:`) are rejected with `Could not parse subworkflow`. A standalone workflow's full form can therefore be its own subworkflow
  interface — the design of `workflows/dakota-openfoam`.
- **An `editor` input keeps tabs**: a table pasted from a spreadsheet reached the run's
  heredoc tab-separated (verified 2026-10-08, same run), so a parser can split on them.
- **A step-level `if:` on a boolean form input works, on `run:` and `uses:` steps alike**
  (verified 2026-10-08, `workflows/doe-openfoam`): `if: ${{ inputs.postprocessing.generate_images
  == true }}` skipped the four Design Explorer steps of preprocessing (the install, the detached
  `pw endpoints run`, the liveness check and the `wait_for_endpoint` call) when the form said
  `false`, and the steps after them ran. That is how a `uses:` step is made optional: a bash
  guard cannot skip a subworkflow call.
- **`range` sizes a matrix straight from a form input** (verified 2026-10-13, runs on
  activate.parallel.works): `job_id: ${{ 1 range inputs.n + 1 }}` expands to `[1, ..., n]`
  and `${{ range inputs.n }}` to `[0, ..., n-1]` (the `+ 1` binds to the end operand;
  `1 range (inputs.n + 1)` is the same list), in a top-level workflow and in a subworkflow
  whose `n` arrives through `with:` from the parent's form. It replaced the sliced literal
  list (`[1, ..., N] get 0:(inputs.n)`) in `tutorials/optimization`, `workflows/doe-openfoam`
  and `workflows/dakota-openfoam`; `n_cases`/`batch_size` now cap at a form `max: 256`. What a
  matrix still cannot take is a runtime value, however it travels: a parent that passes
  `workers: ${{ needs.main.steps.pick.outputs.workers }}` to a subworkflow whose matrix
  ranges over `workers` fails at submission with `Could not expand matrix jobs`, because
  the subworkflow's matrix is expanded when the parent is submitted, before any step has
  run. Until 2026-10-08 (CLI v7.105.0) a dry-run of `range inputs.count` failed with
  `Expression Parser Error: max recursion exceeded` (core PR #20674 brought `range` and
  `fromJSON`; `fromJSON` not re-checked since).
- **A run has a budget of 1000 YAML references, and every matrix slot that calls a
  subworkflow spends them** (verified 2026-10-13, dry-run): with the matrix sized from the
  form, `tutorials/optimization/general.yaml` validates at `batch_size` 999 and fails at
  1000, `workflows/doe-openfoam` and `workflows/dakota-openfoam` at about 500 cases (each
  case is `openfoam-naca`, which calls `script_submitter`: two references per slot, plus
  the page's), all with `[ERROR] workflow run exceeds total YAML reference limit (1000)` at
  submission. Dry-run the widest form value a workflow is meant to take; a form `max:` is
  the place to say what fits (those three cap `batch_size`, `n_cases` and `max_parallel`
  at 256).
- **List-template `default:`s do not fill explicit empty strings (probable platform
  bug — verified July 2026).** Three paths behave differently for a field passed as
  `""`: a **top-level input** is default-filled; a value passed **directly to a
  subworkflow input** is filled by that subworkflow's own default; but a **list-template
  field** (e.g. `workers[0].slurm.time` from an inputs JSON copied off a past run)
  stays `""` and flows through `with:` chains untouched. Consequence: an empty
  `slurm.time` reaches `script_submitter`, and the `general`/`emed`/`noaa` variants
  emit `#SBATCH --time=` → `sbatch: error: Invalid --time specification` (only `hsp`
  guards it). Do NOT patch the submitters and do NOT add warnings to the tutorials —
  Alvaro is reporting the `default:` behavior to the platform devs (July 2026); expect
  it to be fixed platform-side. If a scalar input must be guarded, a ternary works
  (`"${{ x == '' ? '1h' : x }}"` — quote it: the ternary's `: ` breaks plain YAML scalars).

- **An unset optional `editor` input is null to the expression layer, not `''`**
  (verified 2026-10-16, probe runs oriented-hare, present-vulture, coherent-trout): it
  renders empty in the shell, yet `if: ${{ inputs.x != '' }}` and the bare
  `if: ${{ inputs.x }}` are both true when it is unset, and so is `!= ''` with
  `default: ''` on the input. `if: ${{ inputs.x != null }}` (or `!= undefined`) is
  false when unset and true when set: that is the test for "commands were given".
- **A `hidden`/`ignore` condition that tests an unset input with `==` never fires**
  (verified 2026-10-27 with dry-runs, which check required fields): at launch an omitted
  optional input equals nothing (`== ''`, `== null`, `== undefined`, `!inputs.x` are all
  false, `default: ''` does not help; every `!=` is true), so the field stays shown and
  required and the launch fails with `Missing required fields`, from the CLI too
  (2026-10-20, `workflows/openproject`'s client secret, which keeps `optional: true` for
  that reason; `optional` takes no expression). Compare with `!=` to the value that
  needs the field, or drive the condition from a dropdown, which always has a value.

- **An input path the form does not declare renders empty, silently** (verified
  2026-10-28, run summary-poodle): `${{ inputs.resource.ip }}` in a form whose resource
  lives under `inputs.head` became `case "" in` and the step carried on; `--dry-run` does
  not catch it. When a `case` or `if` on an input never matches, read the rendered
  `logs/<job>/step_N/script-unstable.sh` for the empty value.
- **In the launch form the user workspace is an object with only `id` and `uri`**
  (2026-10-28, `workflows/probe`'s `api_key`): a `hidden:`/`ignore:` condition on
  `inputs.resource.name`, `.provider` or `.ip` never fires for it; the full object
  (`name`, `ip`, `provider`, `schedulerType`) exists only once the run resolves the
  resource. Test `inputs.resource.id == 'user-workspace'`; a cluster carries its full
  object in the form, so `provider == 'existing'` keeps working beside it. To see the
  object a form input holds, add a temporary `string` input with
  `default: ${{ toJSON(inputs.resource) }}` and `prefillDefault: true`: the form
  shows it filled in.

## Jobs, outputs, matrix and retries

- **A matrix over a computed list fails at submission** (`Could not expand matrix
  jobs`, dry-run and real run alike): matrix expansion is static — form inputs and
  literals only. Fan out over a runtime-computed set with a **guarded static
  matrix**: a matrix over the form's width (`job_id: ${{ 1 range inputs.n + 1 }}`, or a
  literal list) + `if: ${{ matrix.job_id <= needs.<job>.outputs.N }}` on the matrix job
  (the dcs-workflow honda-japan pattern; guard-vs-output verified). Fallback: submit the
  matrix workflow as a fresh run from a step (`pw workflows run <abs yaml> -i '<json>'`,
  then poll the slug) — reference §3.
- **A matrix can follow a form input** (verified 2026-10-01 with the sliced literal list
  `${{ [1, 2, 3, 4, 5, 6, 7, 8] get 0:(inputs.batch_size) }}`, 2026-10-13 with
  `${{ 1 range inputs.batch_size + 1 }}`), in a top-level workflow and in a subworkflow
  whose `batch_size` arrives through `with:` from the parent's form. What a matrix still
  cannot take is a runtime value (`needs.*.outputs`), so the per-slot
  `if: ${{ matrix.job_id <= needs.<job>.outputs.N }}` guard stays for the count the run
  actually produces, and the guard step that compares N against the width compares it
  against the input (`tutorials/optimization/iteration.yaml`).
- **A matrix can be sized by a ternary over form inputs, but quote the whole value**
  (verified 2026-10-08, run holy-worm, when `workflows/doe-openfoam` still sliced a literal
  list): `job_id: "${{ [1, ..., 32]
  get 0:(inputs.doe.method == 'csv' ? 32 : inputs.doe.n_cases) }}"` expanded to 32 slots
  when the form said `csv` (5 ran, the rest skipped by the runtime guard). Unquoted, the
  ternary's `: ` makes the line invalid YAML and the platform answers only `Invalid YAML`.
- **`strategy.max-parallel` takes a form input** (verified 2026-10-08, `workflows/doe-openfoam`):
  `max-parallel: ${{ inputs.doe.max_parallel }}` with 4 ran four of six matrix workers at once
  and the other two when slots freed. With it the login-node mode has a cap on concurrent
  solvers, which `batch_size` alone does not give a sweep.
- **A matrix instance cannot read its own earlier step's outputs** (verified 2026-10-01):
  `${{ needs.workers.outputs.V }}` in step 2 of matrix job `workers`, where step 1 wrote
  `V`, fails the step with `Expression Parser Error: output V from job workers not found`
  (same for `needs.workers.steps.<id>.outputs.V`); the instances are `workers-0`,
  `workers-1`, … and the bare job name resolves to none of them. Nor can a per-slot
  value be looked up in an upstream job's outputs by computed key:
  `${{ needs.gen.outputs get matrix.job_id }}` returns a character of the stringified
  map, not the entry. So a matrix slot that must feed per-slot data into a `uses:` step
  passes **paths built from `matrix.job_id`** and lets the subworkflow read the file
  (`workflows/dakota-openfoam/yamls/iteration-naca.yaml`: `case.params_file`).
- **`needs.<job>.outputs.X` only resolves for jobs listed in `needs:`**, however far
  upstream: a `results` job that `needs: [run_case]` cannot read
  `needs.preprocessing.outputs.CASE_DIR` (`Expression Parser Error: job preprocessing not
  in needs`, the step fails at parse time, 0 s, no `logs/<job>/` dir at all). List every
  job whose outputs a job reads (verified 2026-10-01).
- **Publish step outputs from a file, not from a program's stdout**: `prog | tee -a
  $OUTPUTS` also sends its `::notice::` lines there, and a `set -e` step without
  `pipefail` hides the program's failure behind `tee`'s success. Write `KEY=value` lines
  to a file and `cat` it into `$OUTPUTS` (`workflows/doe-openfoam`, Sample the Designs).
- **`if:` status checks are the functions `success()`, `failure()`, `cancelled()`
  (also `canceled()`) and `always()`; the keywords are gone** (ACTIVATE v7.112; every
  platform runs a later version). The keywords v7.69 added — `completed`, `error`,
  `canceled`, `never`, their `!` forms, and `success`, `failure`, `cancelled` without
  parentheses — no longer exist: only the word `always` on its own still works, as the
  older spelling of `always()` (write `always()`). Any other bare word is a non-empty
  string, which is true, and an `if:` that calls no status function keeps the implicit
  `success()` check, so an old condition still loads but means something else:
  `${{ !completed }}` and `${{ !error }}` are always false (the job never runs),
  `${{ error }}` runs only when nothing failed, and
  `${{ inputs.fallback ? error : never }}` runs whenever its needs succeeded. Write
  `!success()` (a needed job failed or was cancelled; it keeps running through a
  cancel), `failure()`, `cancelled()`, `!failure()`, and `false` for `never`; the
  table is in `tutorials/if-conditions/`. Entries below verified before the change
  name the keyword they used.
- **A canceled job publishes no outputs, even for steps that completed** (verified
  2026-10-01): a handler job with `if: ${{ !completed }}` (now `!success()`) that read
  `needs.preprocessing.outputs.SERVER_PID_FILE` after a run cancel failed at parse time
  with `output SERVER_PID_FILE from job preprocessing not found`, although the step that
  wrote the output had finished. Handlers that must work after a cancel read fixed
  paths (`${PW_PARENT_JOB_DIR}/<file>`) and inputs, never upstream outputs
  (`workflows/dakota-openfoam/yamls/general-naca.yaml`, `stop_server_if_unhealthy`).
- **A `!success()` handler job runs after `pw workflows runs cancel`** (verified
  2026-10-01 as `if: ${{ !completed }}`, the keyword it replaces; not yet re-run with
  the function): the canceled run showed `preprocessing: canceled`, `wait_for_endpoint:
  skipped-failed` and the handler job executed. That is the hook for "kill what a
  plain step started detached when the run did not get to its health check"; a
  step-level `cleanup:` is not, because cleanups always run at the end of their own
  job (docs: yaml-fields), which would kill a detached server right after launch.
- **After a `pw workflows runs cancel`, only the submitter's cleanup script was seen to
  run** (verified 2026-10-12, `workflows/cwl-mpi-hello-world`, three runs).
  A plain step the cancel reached is killed with its remote process tree, but what that
  process had *submitted* (the SLURM job cwltool sbatch'd) survives, and every YAML-side
  cleanup hook was skipped: a job-level `cleanup:` list showed `(skipped, 0s)`
  (giving-silkworm); a step `if: ${{ canceled }}` in the canceled job was skipped, and a
  handler job `if: ${{ canceled || !completed }}` on it resolved `"if": false` →
  `skipped-failed` (smashing-asp) — the if-conditions tutorial's cancel row holds for a
  `parallelworks/cancel-jobs` self-cancel while the run continues, not for a user cancel
  of the run (and contrast the 2026-10-01 entry above, where such a handler did run; do
  not rely on it for a user cancel). Both of those conditions are keywords ACTIVATE
  v7.112 removed (the first entry of this group): as text, `canceled || !completed` is
  true and keeps the implicit `success()` check, which a cancel fails, and that likely
  explains the contrast. So only the `cleanup:` result is evidence about user cancels;
  re-test `cancelled()` and `!success()` before relying on them for one. What worked:
  run the process under `script_submitter` with `define_cleanup_script: true` and a
  `cancel.sh` that scancels the recorded job ids — on cancel the submitter killed the
  process group and `cancel.sh` scancelled the running 10-node job (clever-blowfish).
  Handler jobs with `if: ${{ !success() }}` remain the hook for the *error* path.
- **A subworkflow's own `if: ${{ !success() }}` handler runs when the top-level run is
  canceled** (verified 2026-10-08 as `!completed`, run included-corgi): canceling a
  doe-openfoam run while its nested `workflows/design-explorer` call had started its
  server showed that subworkflow's `preprocessing` canceled and its
  `stop_server_if_unhealthy` completed, which deleted the half-registered endpoint; no
  process was left. So a reusable workflow that starts something detached can own its
  cleanup, and its callers need no handler of their own for it.
- **`retry.timeout` defaults to 30 s PER ATTEMPT** (documented in
  building-workflows/yaml-fields; bitten and verified 2026-09-29): a `retry:` block
  without `timeout:` cancels each attempt of that step ~25-30 s in — for a `uses:`
  step that means the WHOLE subworkflow attempt, every job, mid-simulation, however
  deep the nesting. The symptoms mislead badly: the killed jobs exit 143 with no
  error of their own, a submitted SLURM job shows `CANCELLED by <you>` (the
  submitter's cleanup scancel), and it RACES — attempts that finish under ~25 s
  succeed, so fast tests pass while scheduled or slow production cases die
  (a minimal repro: a retried `uses:` step whose subworkflow sleeps 120 s fails;
  add `timeout: 10m` and it completes). Always set `retry.timeout` on a retried
  subworkflow step, sized for the whole attempt (queue + node boot + work):
  `workflows/dakota-openfoam/yamls/general-naca.yaml` exposes it as a form input.
  `tutorials/optimization/general.yaml`'s Iterate step has this latent bug
  (its ~15 s test waves win the race; any real solver loses it).

- **An `if: ${{ always() }}` step cannot undo a step that failed before it** (verified
  2026-10-16 as `if: ${{ always }}`, the older spelling, probe run settling-hedgehog):
  after a retried step ran out of retries, the `if: always` step ran and exited 0, and
  the job and the run still ended `error`. A loop's verdict therefore has to be the
  status of the retried step itself (the openfoam-naca restart variants'
  `restart.attempt`). The comment above
  `tutorials/optimization/general.yaml`'s Report step, which counts a loop that ran out
  of retries as success when its state says CONVERGED, does not hold.
- **A job that `needs` a skipped job still runs; one that `needs` a failed job does
  not** (verified 2026-10-16, probe runs rational-beetle, coherent-mongoose,
  lucky-amoeba): with the default `if:`, `needs: [check]` ran after `check` was skipped
  by its own `if:` and after it completed, and stayed unrun (the run in error) after
  it failed. So an optional check job needs no special guard downstream. A job-level
  `if: ${{ !error }}` or `${{ !error && !canceled }}` never ran in the same probes,
  even with its needed job completed: those keywords were already removed, and the
  negation of the text `error` is always false (the status-functions entry above);
  `!failure()` is the condition they meant. `pw workflows runs view` hides skipped
  jobs, so a job missing from its listing was skipped.
- **A nested workflow's jobs run in the caller step's directory,
  `subworkflows/<job>/step_<index>/` under the run's job directory, the same on every
  retry** (verified again 2026-10-16): its checkout and anything it creates relative to
  its working directory (a default case directory) persist across attempts there, so
  a later step of the caller's job can read them by that path. The openfoam-naca
  restart variants' `Report` step runs the attempts' copy of `restart-report.sh` from
  `${PW_PARENT_JOB_DIR}/subworkflows/solve/step_0/` and guards against it missing
  (no attempt got as far as the checkout). Moving the retried step changes the index.

## Resources, nodes and filesystems

- **Resource passing:** bare name string in `-i` for `compute-clusters`, not a
  hand-built object; login IPs change, so never hardcode `ip`. A **kubernetes**
  resource is the exception: it must be the object described in reference §2.
- **`workspace` resolves with empty `ip`** → its SSH steps run on the workspace node
  (a *different* host than a cluster login node). Match your debugging location to
  the resource you chose.
- **A workspace job can stay `canceling` after `parallelworks/cancel-jobs`** (seen
  once, 2026-10-28): of two runner jobs released a second apart by their wait jobs, one
  reached `canceled` and the other stayed `canceling`, its wait job's last step never
  recorded although the cancel was logged as successful, the service was live and no
  process was left; the run then refuses `pw workflows runs cancel`
  (`run_not_cancelable`). The rerun passed and clusters never showed it: a race in the
  workspace executor. Rerun, and report the run.
- **Scheduled jobs run on a compute node** that may lack `${PW_PARENT_JOB_DIR}`; use
  paths relative to `rundir`. Cloud-burst nodes are slow to provision (**6+ min**
  observed; `idle~ → CF → RUNNING`, `POWERING_UP` while booting) — watch with
  `squeue`/`sacct` on the login node and poll with long intervals; it's not a hang.
- **Cross-cluster filesystems are separate:** a code/data path staged on one resource is
  absent on another — stage it on the resource that runs it. If a required path is missing,
  **fail loud (exit non-zero), don't silently skip**: a silent skip upstream plus a
  downstream job waiting on its output (e.g. a port file) becomes an indefinite hang.
- **Only the workspace and `existing` resources carry the platform SSH key** (`~/.ssh/pwcli`,
  verified 2026-09-23: present on the workspace and an existing cluster, absent on a cloud cluster's login
  node, where `pw ssh` outside a run also has no context). A job that opens `ssh -i
  ~/.ssh/pwcli ... -R` tunnels to other resources must run on one of those hosts; a
  same-resource target needs no tunnel at all (see `workflows/burst-render-demo`).
- **A run can leave `~/.ssh/pwcli` on a cloud login node** (observed 2026-10-07, cloud cluster):
  the key was absent before the first app-testbed run and present after it, so a script
  that branches on the key's presence can take another branch on a node a run has used.
- **`nproc` inside an `srun` task counts the task's CPUs, not the node's** (verified
  2026-10-09 on a cloud cluster: 1 by default, 4 with `--cpus-per-task=4`, still 1 with
  `--exclusive`). A worker pool sized from `nproc` (an "auto" threads option) runs one
  worker per node unless the step asks for `--cpus-per-task` (`workflows/monte-carlo-pricing`).
- **`pw forward` target host (verified):** forward a service to localhost with
  `pw forward -L p:host:p <resource>` — `host=localhost` when the service is on the
  **login node** (unscheduled; its external hostname is NOT reachable), `host=<HOSTNAME
  file value>` when it's on a **compute node** (scheduled). Pick by the scheduler flag.
- **"HPCMP login nodes have no internet" is per system, not a rule:** Nautilus's login
  node reaches GitHub and conda-forge (HTTP 200, 2026-10-05), has no Dakota module, and
  the conda-forge Dakota install worked there. Test with `curl` before telling a user
  to bring a module.
- **Kubernetes-specific pitfalls** (quota, guards, sidecar lifecycle) are collected in
  [references/k8s-workflows.md §9](k8s-workflows.md).
- **A pod that is `OOMKilled` in a restart loop looks like a slow start: the endpoint
  answers `503` for the whole budget** (verified 2026-10-07, `workflows/mlflow` on a k3s cluster):
  the sidecar registers at once, the proxy returns `503` while nothing listens, and the
  streamed log shows the server starting again and again; only `kubectl get pod -o
  jsonpath='{.status.containerStatuses[0].lastState}'` (or the `BackOff` event) says
  `OOMKilled/137`. MLflow 3's `mlflow server` defaults are 4 uvicorn workers plus a job
  runner of 7 huey processes, about 250 MB each (PSS 2.5 GB measured on a cloud cluster), far over
  the k8s forms' 1Gi limit; with `MLFLOW_SERVER_ENABLE_JOB_EXECUTION=false` and
  `--workers 2` it is 700 MB. Measure a new server's footprint on a login node (`ps -o
  rss`, or PSS from `/proc/<pid>/smaps_rollup`) before trusting the shared 512Mi/1Gi
  defaults, and probe the image in a pod with the same limits first (k8s reference §3).

- **A cloud node that never finishes booting holds the job in `CONFIGURING` for the
  whole `ResumeTimeout`, then fails it and SLURM requeues it** (verified 2026-10-16 on
  gcptest, `ResumeTimeout = 1200 sec`: job 62 of a doe-openfoam run sat `CF` on a node
  shown `mixed#` for 20 min, ended `NODE_FAIL`, and ran on another node after the
  automatic requeue, `Requeue=1 Restarts=1`; the submitter's monitor followed it and the
  run completed 20 min late). A retried attempt whose `timeout` is shorter than queue +
  `ResumeTimeout` + walltime is cancelled before such a requeue gets to run
  (`workflows/openfoam-naca/yamls/general-restart.yaml`, `restart.attempt_timeout`).
- **The test runner counts every queued job of the user after a scheduled test**
  (`squeue -h -u $USER`), not only the test's own: an interactive `srun bash` running
  meanwhile makes the row read `cleanup=leftover:squeue` (2026-10-16). Check with
  `sacct` that every job named `inline.<slug>-…` completed before reading it as a leak.

## `script_submitter` and scheduler jobs

- **`script_submitter` with `use_existing_script` and `script_path: ./run.sh` wraps its own
  output on a retry** (verified 2026-09-30): the submitter writes its assembled job script
  as `run.sh` in `rundir`, so a step that re-submits the same dir copies the assembled
  script as the template and prepends the headers again (doubled `#SBATCH` lines, the
  `hostname > HOSTNAME` line twice). Name the script you hand it anything else
  (`workflows/openfoam-naca`: `case.sh`; `tutorials/optimization` still has the collision).
- **A directive a workflow injects ahead of the form's `scheduler_directives` stays
  overridable:** sbatch keeps the LAST value of a repeated option (`--ntasks=2` then
  `--ntasks=3` → `NumTasks=3`, verified 2026-09-30 with `sbatch --hold` +
  `scontrol show job`), so compose `<workflow lines>\n${{ inputs.slurm.scheduler_directives }}`
  in the `with:` block (a `|` block scalar with expressions renders fine) and the user's
  line wins when they repeat it (`workflows/openfoam-naca/yamls/general.yaml`).
- **A scheduled job gets one core unless the script asks for more, and a threaded
  application can stall on it** (verified 2026-10-23, an AWS GPU cluster, `workflows/omniverse` run
  pet-earwig): `task/affinity` pinned the process to core 0 and Kit's task system never
  advanced past the first frame; `--cpus-per-task=8` composed ahead of the form's
  directives (the `cluster.cpus` input) fixed it. Details in
  [software/omniverse-isaac-sim.md](software/omniverse-isaac-sim.md).
- **The hsp and noaa submitters write SLURM headers in a different order than
  `general`, which decides what a directive can override** (read from the submitters,
  2026-10-02; the `existing`-only lines cannot be exercised from a cloud cluster):
  `general` emits the fixed headers, `--partition` and then the directives; `hsp` adds,
  for `existing` resources, `--account/--qos/--cpus-per-task/--nodes[/--constraint]`
  *before* the directives, so a `#SBATCH --nodes=...` typed or composed in
  `scheduler_directives` still wins (sbatch keeps the last value of a repeated option);
  `noaa` adds `--account/--qos/--ntasks/--nodes` *after* the directives, so there a job's
  shape must go through the submitter's `ntasks` and `nodes` inputs, not through a
  directive (`workflows/openfoam-naca/yamls/noaa.yaml` passes `ntasks: cores_per_case`,
  `nodes: 1`, and composes the same two directives for every other resource). `hsp`
  also guards an empty `slurm.time`.
- **Nested subworkflow job dirs live under the parent run's** (HSP, Nautilus, 2026-10-05):
  the subworkflow a `uses:` step at index k of job J ran has its job dir at
  `<run dir>/subworkflows/J/step_k/`, recursively, with its own `logs/`, `subworkflows/`
  and checkout; matrix instances are `workers-0..N-1` (zero-based). A worker's failing
  step of the Dakota-OpenFOAM loop was
  `.../subworkflows/optimization_loop/step_0/subworkflows/workers-3/step_0/logs/preprocessing/step_1/step.out`.
  Read every failure of a run at once with
  `find <run dir> -name step.out | xargs grep -h '^::error' | sort | uniq -c` — the top-level
  Report step only says what the state files say, never why a worker died.
- **The submitter runs the start script in its own directory, not the run's job dir**
  (verified 2026-10-09, `workflows/postgres`, run cheerful-kingfish): with `rundir` left
  blank, `script_submitter` executes in `<job dir>/subworkflows/session_runner/step_0/`,
  where `cancel.sh` and whatever the start script writes land. A file preprocessing wrote
  into the job dir (there, the mode-600 password files) is not beside it; reach it as
  `${PW_PARENT_JOB_DIR}/<file>`. `inputs.sh` carries `PW_PARENT_JOB_DIR` (it is written
  from `env | grep '^PW_'`), so the path also resolves in a SLURM job on a compute node
  (run sacred-ram), and a later step in the job dir reads what the start script writes there.
- **A login-node-only service can skip `script_submitter`**: start it with
  `setsid pw endpoints run ... > out 2>&1 < /dev/null &` from a plain step
  (`tutorials/endpoint-workflows/03-exit-workflow.yaml`), keep `wait_for_endpoint` as
  the health check (no `skip_cleanups_file`), and add the `!success()` handler above
  because an endpoint that never registered cannot be removed with `pw endpoints
  delete`. `workflows/dakota-openfoam` serves its Pareto page this way.
- **A batch script killed by `scancel` runs its EXIT trap with `$?` = 0** (verified
  2026-10-06, `workflows/benchmarks`): SIGTERM reaches bash while it waits for the
  benchmark pipeline, bash runs the exit trap on the way out, and `$?` there is the status
  of the last command that *completed*, the `echo` before the pipeline, so a
  `trap 'echo $? > x.exit' EXIT` records `0` for a cancelled job. Trap the signals too
  (`trap 'exit 143' TERM`, `130` INT, `129` HUP) so the exit file says killed, **and run
  the long command in the background with `wait $!`**: bash defers a trap until a
  foreground pipeline ends, and an `mpirun` that got SIGTERM kept its IOR ranks writing
  for 54 s (2026-10-07), past SLURM's `KillWait` (30 s here), so SIGKILL took bash and
  no trap ran at all; in `wait` the trap runs at once. Wrap the pipeline in a subshell
  with `pipefail` so `wait` returns the command's status, not `tee`'s. **Killing the
  job's process group does not end Open MPI ranks**: `mpirun` puts every local rank in
  a process group of its own (verified with `ps -o pid,pgid`: two `ior` ranks each had
  their own pgid while `mpirun` shared the subshell's), so a `kill -- -<pgid>` left the
  ranks writing and the `rm -rf` of their directory failed with "Directory not empty".
  Walk the tree (`pgrep -P`, recursively, captured *before* the first kill, since
  orphans re-parent) and signal the pids, then SIGKILL; the removal is retried while
  ranks on other nodes die with the step. The submitter's
  cleanup script stays the belt and braces (and on `hsp` it cannot reach the node: that
  submitter writes `HOSTNAME` after the script). `activate-batch`'s `commands.exit` has
  the same latent `0`; harmless there because a cancelled run never reads it.
- **SLURM's walltime SIGTERM reaches the batch script alone, not its children** (verified
  2026-10-16 on gcptest with a 1-minute job: the script's `trap` fired at the limit, a
  `sleep` it had started lived on until the SIGKILL 30 s later, `KillWait`, and the
  batch step ended `CANCELLED` after 1:29). A solver started by the script therefore
  runs on, unrecorded, until the SIGKILL, mid-write or not. Forward the signal down:
  the batch script runs the real script in the background with a `trap` that forwards
  TERM/INT/HUP to it, and that script forwards to the solver's process tree (walk
  `pgrep -P` recursively: `mpirun` → proxies → ranks) and records the interruption
  (`workflows/openfoam-naca/app/create-case.sh`'s `case.sh`, `app/restart.sh`). bash runs a
  trap at once only while it waits on a *background* job (`wait $!`); a foreground
  command defers it until the command ends, so run every long tool in the background.
  The platform's cancel of a retried attempt goes through the submitter's cleanup
  (`scancel`, or `kill -- -<pgid>` on the login node) and arrives the same way. Both
  paths recorded end to end (2026-10-16): under a 2-minute walltime the SLURM job ended
  `TIMEOUT` at 2:00 and the simulator logged `interrupted (SIGTERM) in simpleFoam` with
  its checkpoints (run sweet-bass); under a 75 s attempt budget on the login node the
  cancel arrived the same way and the runner's leftover check found nothing (run
  smashing-guppy, where the budget also cut an attempt *after* it had solved, and the
  next attempt only extracted the results again).

## Endpoints and the service

- **The service listens on the port `pw endpoints run` assigned** (`{port}` / `$PORT`,
  never a fixed port of its own, or the tunnel forwards to nothing and ports clash).
  The tunnel client runs on the service's node, so the loopback is enough:
  `openproject`, `pydio-cells` and `pgadmin4` publish on `127.0.0.1:${PORT}` (verified on
  login and compute nodes). `0.0.0.0` only matters when another node must reach the
  service directly.
- **The start script returned early, or a teardown left a process:** `pw endpoints run`
  stays in the foreground (it blocks for the service's life; a server started in the
  background needs a `wait` or `sleep inf` after it), or the submitter sees the script end
  before the endpoint registers. Anything that escapes the endpoint's process tree (a
  `screen` session, a docker container, a daemonizing app that re-parents to PID 1)
  survives `pw endpoints delete` unless `cancel.sh` kills it; write `cancel.sh` first thing
  in the start script so a cancel at any moment finds it.
- **A check that must fail the run goes before `pw endpoints run`, on a port you pick**
  (verified 2026-10-12, `workflows/pgadmin4`): the endpoint is listed within seconds of
  `pw endpoints run` starting and `wait_for_endpoint` completes the run the moment the URL
  answers, so a check made after the service is reachable (a login against a reused data
  directory, a migration) can fail after the run has already completed, leaving a
  completed run with a dead endpoint. Find a free loopback port, start the service on it,
  check it, then `pw endpoints run --port <port> -- <foreground command>` (`docker compose
  logs -f` for a container that is already up); `app/start-template.sh` there.
- **Setup that must run after the service answers gates the probed route** (verified
  2026-10-28, `workflows/gitlab`): the first test's teardown came 1 s after the run
  completed, while the launcher was still registering the CI runners behind the
  already-answering sign-in page; a failure there would have left a completed run whose
  cleanup then removed the service. When the setup needs the live service (its API), make
  the route `wait_for_endpoint` probes answer `503` until a marker file exists (nginx:
  `if (!-f <marker>) { return 503; }`, with a header the launcher's own probe sends to
  bypass it), touch the marker last, and keep `exit 1` for every setup failure: the run
  then completes on the whole setup and fails loud otherwise.
- **Endpoint names must be lowercase `[a-z0-9-]`** (undocumented; one uppercase letter
  fails the launch). `<service>-${PW_RUN_SLUG}` is safe; a name typed into a form is not:
  fold it before it reaches `pw endpoints`, and make the wait step look for the same
  folded name (`workflows/ollama/yamls/general.yaml`, input `endpoint_name`).
- **No session subdomains on emed:** register endpoints with `--no-subdomain` there
  (the platform then serves `/me/session/<PW_USER>/<name>/` and forwards the full
  path — give the app that base path). See `workflows/kasmvnc/yamls/emed.yaml`.
- **Base-path apps break on path-based endpoints** if they assume the host root — give
  them the `{path}` token as base URL, or `--strip-path` (reference §10).
- **Browser-side app state dies with a random subdomain:** web IDEs (code-server,
  JupyterLab) keep sign-ins, disabled-extension lists, workspace trust and UI state in
  the browser (localStorage/IndexedDB), keyed by page origin — a new random subdomain
  per run resets all of it (openvscode, 2026-09: Copilot logout, extensions re-enabled,
  folders untrusted every run). Pin the origin with `pw endpoints run --subdomain
  <label>` (a platform-wide DNS label: lowercase `[a-z0-9-]`, ≤63 chars — build it from
  the resource namespace, cluster and `PW_USER`), keep `--name <service>-${PW_RUN_SLUG}` for lookup,
  and check `pw endpoints list` for an endpoint already serving `https://<label>.`
  before launching (see `workflows/openvscode/app/start-template.sh`).
- **The endpoint proxy forwards `X-Forwarded-Proto: http`** (verified 2026-10-20 with a
  header-echo server): an app in HTTPS mode redirects every page to itself, never writes
  its Secure cookie and fails its CSRF origin check ("The OpenProject cookie is missing"),
  while an exempt health route still answers 200. Set the header in a proxy of your own
  and probe a real page: [oidc-sign-in.md](oidc-sign-in.md).
- **PID files in a shared run directory let a refused run kill the live one** (verified
  2026-10-20, `workflows/openproject`): a second run on the same run directory lost the
  lock and exited, and the start script's cleanup trap then ran `cancel.sh`, which
  read the PID files the live run had written there and stopped its services (the
  endpoint went `stopped`). Keep PID files in the run's own job directory (`${PWD}/run`
  of the start script) so a cleanup can only reach what that run started; the lock
  stays in the run directory.
- **Killing a `singularity exec` starter does not reliably stop the process inside**
  (verified 2026-10-20, `workflows/openproject` Singularity launcher): a TERM to the
  starter PID of `good_job start` ended the starter and left the worker running, while
  puma, nginx and PostgreSQL stopped fine. For services a `cancel.sh` must stop, start
  each one as the leader of its own process group (`setsid nohup singularity exec … &`,
  `$!` is then the PGID) and signal the group (`kill -TERM -- -$pgid`, `kill -0 -- -$pgid`
  to see whether anything is left, `-KILL` after a grace period). `nohup` cannot run a
  shell function either: build the common `singularity exec` options as an array and
  pass plain commands.
- **A desktop app's helper re-groups itself and outlives a crashed parent** (verified
  2026-10-28, three runs on a cloud cluster): RStudio's
  `rsession` moved to its own process group, so neither a kill of the startup command's
  pid nor `kill -- -pgid` reached it; it stayed in the session, so the command runs under
  `setsid` and `cancel.sh` kills by session (`pkill -TERM -s $pid`, `-KILL` after a grace
  period) (`workflows/kasmvnc/kasmvnc-singularity/start-template.sh`).
- **Passing secrets and values with spaces into Apptainer** (verified 2026-10-20,
  apptainer 1.4.5, `workflows/openproject`): `--env-file` is evaluated like a shell
  script, so `KEY=openid profile email` aborts every container start (`FATAL: while
  setting environment`) and `$` in a password is expanded; quoting the file does not
  survive either (`'\''` came out as `\'`). `--env KEY=VALUE` is literal but lands in
  the process list. `APPTAINERENV_KEY`/`SINGULARITYENV_KEY` host variables reach the
  container even with `--cleanenv` and stay out of `ps`, but `$…`, backticks and
  backslashes are still expanded in them: escape those three (`sed 's/[\\$`]/\\&/g'`)
  and the value arrives verbatim, double quotes included.
- **A root-only image (its own init, services as several accounts) runs as a
  `--fakeroot` Apptainer instance** (verified 2026-10, `workflows/gitlab/gitlab-singularity`):
  the whole pattern, runtime selection, the three probes (id range, image, state), the
  sandbox and overlay-image fallbacks, the instance flags and the stop sequence, is one
  section of [software/singularity-sif-containers.md](software/singularity-sif-containers.md),
  "An image that needs root". Its symptoms, for grepping:
  - `chown: Operation not permitted` / Ruby `Errno::EPERM @ apply2files` from inside the
    container: the bound directory is on a network filesystem; the state goes into an
    ext3 overlay image.
  - `Permission denied` writing into or unlinking a file the container just created
    read-only (gitaly's unpacked binaries, git's objects): an image bind through fuse2fs
    alone; use the overlay image.
  - An init that waits forever for a service it just configured (runit's `supervise/ok`):
    the service directory sits in a FUSE overlay; bind it from the host.
  - `ssh-keygen: PRNG is not seeded` in the entrypoint: the host runs in FIPS mode; bind a
    `0` over `/proc/sys/crypto/fips_enabled`.
  - `could not find a temporary directory` from Ruby: the container's `/tmp` is not `1777`.
  - `setup of overlay upper dir failed: .../upper is not writable` with `Try appending
    ':ro'`: the overlay image was created without `overlay create --fakeroot`.
  - `Errno::EEXIST: File exists` replacing a file of the image (`ln -sf`), or `rm` that
    succeeds while the file stays: Apptainer 1.3 records no whiteout in an overlay image.
- **An image rebuilt to run as the user** (verified 2026-11, `workflows/gitlab/gitlab-singularity`;
  the recipe is in [software/singularity-sif-containers.md](software/singularity-sif-containers.md),
  "An image that needs root, rebuilt to run as the user"). What its runs tripped over:
  - Chef `Cannot create directory[...] due to insufficient permissions` on a directory
    that exists and is writable: the `directory` resource wants a writable *parent*.
  - Rails `"<path>" is a symlink that does not point to a valid file`: a dangling link
    under `config/initializers` aborts the boot; a regular file that loads the target
    if it exists does not.
  - `undefined method '[]=' for nil` on a nested key of `GITLAB_OMNIBUS_CONFIG`: a
    `from_file` before it turned the DSL's auto-vivify off; `eval File.read(...)` in place.
  - `rm -rf <dir>/` exits 1 once `<dir>` is a symlink: `rm -rf <dir>/*`.
  - Apptainer `--writable` with `--home <src>:<dest>` under `/var` hides every other
    bind under `/var` (`destination ... doesn't exist in container`): use `--bind`.
  - `apptainer instance stop -F <name>` prints its usage (exit 1) when the instance
    does not exist.
- **The session proxy rewrites every redirect to another host onto the session's own
  host** (verified 2026-10-20): an OIDC/OAuth sign-in or RP-initiated logout never reaches
  the identity provider. Intercept external 3xx in your own proxy and answer a hop page:
  [oidc-sign-in.md](oidc-sign-in.md).
- **An app that signs users in with ACTIVATE (OIDC)** (verified 2026-10-20,
  `workflows/openproject`) needs an app registered for its exact URL, a pinned subdomain
  and a proxy of its own in front; the recipe, the claims and how far curl can test the
  flow are in [oidc-sign-in.md](oidc-sign-in.md).
- **A command-line client cannot authenticate to the served app through the endpoint**
  (verified 2026-10-28, `workflows/gitlab`): the proxy wants the platform's login or a
  bearer key and strips `Authorization` before the app sees it, so `git clone
  https://<endpoint>/...` (and any client that sends its own `Authorization`) reaches the
  app anonymous at best. Publish the app's port on the node's loopback too and send
  clients there: `localhost:<port>` from the cluster, `pw forward -L` from a laptop; a
  helper on the node that must call the app's API (a CI runner, Jacamar's JWKS fetch)
  gets the loopback URL as well, never `CI_SERVER_URL`
  ([software/gitlab.md](software/gitlab.md)).
- **`pw agent open-port` is a TOCTOU trap for slow-starting services:** the port
  sits unbound while the service boots (a SIF conversion takes ~1 min), and busy
  siblings on the node (MATLAB's dynamic services) steal it from the ephemeral
  range in that window — three retries collided in a row. For services with a
  slow bind, derive ports below the ephemeral window (32768+; e.g. 25900+display)
  from a node-unique value instead (see kasmvnc's start template).
- **`pw endpoints run` substitutes `{port}` inside a longer argument** (verified 2026-10-07,
  `workflows/app-testbed`): `-- sh -c "exec python3 server.py {port} >> server.log 2>&1"`
  works, and `--port N` pins the port when a client must know it (a worker's tunnel).
- **A run cancel can leave the endpoint record in `pw endpoints list` as `stopped`**
  (observed 2026-10-07, `workflows/mlflow` on a cloud cluster): `pw workflows runs cancel` while the
  service was starting ran the cleanup trap, MLflow shut down gracefully and no process
  survived, but the listing kept `mlflow-<slug>  stopped` until `pw endpoints delete`; the
  `pw endpoints run` process is killed by the trap's `kill -- -$$` before it finishes
  deregistering. When the submitter's own cleanup does the killing (a failed health check),
  the log shows `Endpoint "<name>" deleted.` instead. A `stopped` record is inert, but a
  cancel-cleanup check should look at `pw endpoints list` too and delete what it finds.
- **MLflow 3 answers 403 behind the endpoint while `/health` says 200** (verified
  2026-10-07, `workflows/mlflow`): since 3.5 the server validates the `Host` header
  against an allow-list (localhost variants and private IP ranges by default; `/health`
  and `/version` are exempt, so a health probe sees nothing wrong) and blocks POST/PUT/
  DELETE API calls whose `Origin` is not allow-listed, which the browser UI sends on every
  same-origin POST. The platform proxy forwards the public endpoint host, so the first
  `GET /` got `403` after the `503`s of startup, and the pod log says `Rejected request
  with invalid Host header: <endpoint host>`. Setting `--allowed-hosts` *replaces* the
  defaults (the node's own FQDN is not in them either; its IP is). On a cluster, compose
  `--allowed-hosts` and `--cors-allowed-origins` in a launcher from `PW_ENDPOINT_HOST`
  (exported by `pw endpoints run`, pw ≥ 7.105) plus `hostname -f`, `hostname -s` and
  `hostname -I`; inside a pod served by the `pw-cli` sidecar the host is unknown when the
  container starts, so set `MLFLOW_SERVER_ALLOWED_HOSTS=*` and
  `MLFLOW_SERVER_CORS_ALLOWED_ORIGINS=*` (the pod has no Service; the tunnel is the only way
  in). `pw endpoints run --rewrite-host` alone is not enough: it rewrites `Host`, not
  `Origin`.
- **curl is not a websocket probe:** `curl -H 'Upgrade: websocket' …` returned 404
  from a websockify path that a raw HTTP/1.1 upgrade request (python socket) got 101
  from. Test handshakes with a raw request before blaming the route.
- **Test the failure path on purpose:** make the start script `exit 1` before
  `pw endpoints run` and check the run ends in `error` — the success path never
  exercises the error-handling steps.
- **Test through the real client path, not a stand-in.** Reach the service the way
  the user will — through the platform proxy, endpoint URL or chat — not just a local `curl`.
  Proxy-only failures (SSE streaming resets, base-path rewrites, ~60s timeouts) pass
  a localhost curl and a non-streaming call, then fail in the actual UI. When a
  service works locally but fails through the platform, read its **own stdout/stderr
  log in the job dir** — the traceback there pinpoints the cause fast.
- **Reuse the platform's native surfaces — don't hand-roll UI.** For a chat-style
  service, make it OpenAI-compatible and expose it with `pw endpoints run --openai` so it
  joins the built-in chat; every model its `/v1/models` lists becomes a chat model and the
  list is re-polled. If an agentic/streaming service is flaky in the chat, serve its own
  web UI as a plain endpoint instead. SSE must be framed for the proxy. (Reference §11.)
- **LLM "brain" = the platform endpoint + runtime `PW_API_KEY`** (+ `X-Allocation`
  for `org:*` models) — no external key or org secret. The key is in every step's
  environment on its own; keep it out of `inputs.sh` (the `grep -v PW_API_KEY`
  convention) and read it from the runtime env ([pw-auth.md](pw-auth.md)).
- **Prove the risky/novel mechanism on real infra early**, before the full workflow
  is wired. For a distributed piece (e.g. cross-node `pw ssh` calls), stage the
  script on the target node and exercise it directly, then wrap it in YAML.

- **A page on the vendored theme shows one mode only, or none, without `color-scheme`**
  (verified 2026-10-19, PROBE): `theme.css` pairs each token's modes with `light-dark()`,
  which follows the root's `color-scheme` (`light dark`: the device; `light` or `dark`:
  pinned). Set it from one attribute the page writes before its first paint; never
  redefine the tokens per mode ([app-ui.md](app-ui.md)).

## `pw` CLI, auth and remote shells

- **A credential passed as an input is checked at the first `pw` call that uses it, not
  by the form** (verified 2026-10-19, PROBE run `wealthy-rattler`): an expired key reaches
  `pw endpoints run` and the service dies with `[ERROR] Unauthorized` in `run.*.out`,
  while the step log only says `pw endpoints run failed`. The CLI's own token in
  `~/.config/pw/credentials` expires hourly and is refreshed only by a `pw` command: run
  one before reading it, or pass a real API key; a `pw auth whoami` before
  `pw endpoints run` fails the run with the reason.
- **A `pw` call inside the run gets `401 Unauthorized`:** the workflow (or the parent
  of the subworkflow making the call) lacks `permissions: ['*']`.
- **`pw workflows run` with a relative YAML path:** CLIs before v7.105 parsed it as a git
  host and failed with a bogus DNS/GitLab error; v7.105.0 accepts `./x.yaml` and `x.yaml`
  (dry-run verified 2026-10-12). Still pass the **absolute path**: the shell's cwd is not
  guaranteed between tool calls, and `create --yaml` with an unreadable path makes an empty
  workflow (below).
- **`pw` auth expires** (short-term tokens): a day-old shell suddenly failing every
  command with "Authentication has expired" needs the user to run `pw auth` — it
  prompts for a credential; there is nothing the agent can mint itself.
- **A run's `PW_API_KEY` is rejected as soon as the run ends** (verified 2026-09-24): a
  service the run started keeps serving (open `pw endpoints run` and `pw ssh`
  connections run on their own key) but its `pw` calls fail with `Authentication has
  expired`. Plan a teardown that needs no `pw` call (`workflows/ray-cluster`), or hand
  the service a credential that outlives the run ([pw-auth.md](pw-auth.md)).
- **`pw ssh <resource>` suddenly answers "Cluster not found or you do not have sufficient
  permissions"** and `pw cluster ls` lists another platform's clusters: the CLI's current
  context changed under you (the user switched it in another shell; `pw context list`
  shows the `*`). Pin every call with `PW_CONTEXT=<context-name>` (or `--context`) instead of
  switching the global context back, which would break their shell (verified 2026-09-30).
- **`pw workflows run <name>` uses the STORED definition.** After editing a YAML,
  `pw workflows update <name> --yaml file.yaml` first, or the run uses the old form
  (e.g. `400 Missing required fields` for an input you removed).
- **`pw workflows create --yaml <path>` with an unreadable path still creates the
  workflow — empty** ("workflow created but failed to read YAML file"), and a
  subsequent `run` executes that empty definition instead of erroring. The Bash shell
  cwd is not guaranteed between tool calls — pass the YAML as an **absolute path**, and
  recover with `pw workflows update <name> --yaml <abs-path>`.
- **Long synchronous requests through the platform proxy can `502 Proxy Error`**
  (~a minute+ exceeds the proxy timeout). Stream to keep bytes flowing, or use an
  async job+poll pattern for long work.
- **Transient `pw workflows run/cancel` API timeouts happen** — just retry.
- **A `pw ssh` call that launches a detached script and then keeps working did not
  return** (2026-10-07, twice, `workflows/dask-slurm`'s dev loop): `pw ssh <r> 'setsid
  nohup bash script.sh > out 2>&1 < /dev/null & sleep 25; cat out'` and a `bash -c` whose
  body backgrounds a long-lived python stayed open for minutes, past the tool timeout,
  while `pw ssh <r> 'setsid nohup bash -c "..." > log 2>&1 < /dev/null & echo started'`
  (nothing after the launch, nothing backgrounded inside) returned at once. Stage the
  script with `pw ssh <r> 'cat > remote.sh' < local.sh`, launch it as the last thing in
  its own call, and poll the logs in separate calls. Kill the leftover launcher shells
  (`ps -u $USER -o pid,etime,args`) or their delayed commands run later against a newer
  state: a demo client from the stale launch connected to the next test's scheduler.
- **`pgrep -f`/`pkill -f` run over `pw ssh` also match the remote shell carrying the command**
  (the pattern is on its command line): bracket one character, e.g. `dispatch_workers[.]sh`.
- **`ssh host 'bash -s'` has no tty, so the remote script gets no signal when the client
  dies**; if it is not writing output it runs on, orphaned. Have it watch its `sshd` parent
  and exit through its cleanup trap when that is gone (`workflows/ray-cluster/app/dispatch_workers.sh`).
- **`faulted`** is the status of a run whose job failed while the others wind down; it never
  completes, so treat it as final.

## Code delivery and tests

- **Code-delivery mistakes:** don't base64-embed; if you used the no-write-access
  copy step, remember it must be swapped for the (currently commented) checkout once
  the branch is merged.
- **Forgetting to push before a run** tests the *old* code: the checkout and `uses:`
  steps fetch from GitHub, not your working tree.
- **Composed checkout paths without the `workflows/` prefix**
  (`"${PW_PARENT_JOB_DIR}/${service_name}"`-style) fail with file-not-found only at
  run time — grep for `PW_PARENT_JOB_DIR` compositions when a script can't find its
  own files.
- **`parallelworks/checkout` leaves no `.git`** (verified 2026-09-24): it materializes the
  files only, so a script cannot read back which repo or branch the run used. To give another
  machine the same code, send what this one already has
  (`tar -czf - ... | ssh <site> "tar -xzf - -C ..."`) instead of cloning there: one branch
  reference instead of two, and it works where the site has no GitHub access
  (`workflows/burst-render-demo`).
- **The test runner's variant is the YAML's basename:** `tests/<variant>/<test>.json`
  launches `yamls/<variant>.yaml`, so a workflow whose YAML is `general-naca.yaml` keeps
  its tests under `tests/general-naca/`. With a wrong directory `--emit` prints nothing on
  stdout (the error goes to stderr) and a dry-run fed from it fails with `Missing required
  fields: Compute resource` (verified 2026-10-01).
- **Two tests launched in parallel on one resource see each other's `pw endpoints run` as a
  leftover** (verified 2026-10-06, marimo + h2o on a cloud cluster): the runner ignores only the
  processes that existed before *its own* launch, and every endpoint workflow's default
  `leftover_patterns` include `pw endpoints run`, so a sibling run's service that started
  later shows up at teardown. The runner waits for it ("waiting for cleanup:
  ['proc:pw endpoints run']") and passes once the sibling is torn down, but a sibling that
  serves longer than the wait turns into a false `leftover:proc:pw endpoints run`. Run the
  tests of one resource sequentially (one `run-workflow-test.py` invocation takes several
  test files and runs them in order).

- **Every PROBE test of a workflow failing at launch with `Missing required fields:
  Service host` (`#/resource`) is a definition whose `inputs` no longer match the form**
  (verified 2026-10-19: 26 definitions still passed `cluster.resource` after the forms took
  the cluster as the top-level `resource` on 2026-10-12; PROBE accepts both, so nothing
  warns). Regenerate them with `workflows/probe/scripts/import_workflow_tests.py` and
  dry-run each against its YAML: a stopped cluster validates with the right shape, so the
  dry-run tells the two apart.

## Shell scripting

- **Never paste JSON into a `python -c` source string.** In `json.loads('''${SITES_JSON}''')`
  python un-escapes the document first, so a `\n` inside a value becomes a real newline and
  parsing dies with `Invalid control character` — one multi-line `editor` input is enough
  (the hsp directives default ends in one; burst-render-demo on `jean`, 2026-09-24). Read it
  from the environment (`os.environ["FOO_JSON"]`) or stdin, and single-quote the python
  source. Keep a multi-line directives value in one recorded test so it stays covered.
- **A backgrounded startup app inherits a closed stdin:** console-driven GUIs
  (vmd) read stdin, get EOF, and "exit normally" right after starting. Launch
  with stdin on a read-write FIFO (`mkfifo f; cmd 0<> f &`) — never blocks,
  never EOFs (verified with vmd on emed).
- **A trap that backgrounds `setsid helper &` and then runs `kill -- -$$` can kill the helper
  before it detaches**: wait for a marker the helper writes first
  (`workflows/ray-cluster/app/start-template.sh`).
- **`tail -8 f1 f2` prints nothing:** coreutils accepts the old `-N` form only with a single
  file; with several it fails with "option used in invalid context" — to stderr, which a
  `2>/dev/null` hides, so a "log tails:" banner comes out empty (verified 2026-09-30, it had
  been silent since the workflow's first version). Always `tail -n N`.
- **A heredoc inside a Python patch script fed through a bash heredoc** ends the outer one at
  the first line that matches its terminator (`EOF` inside `<< 'EOF'`): Python then fails to
  parse and bash runs the rest of the file as commands. Write the patch to a file and run it, or
  pick an outer terminator no inner script uses (`PYEOF`).
- **Quotes inside `${var:+...}` in an unquoted heredoc are dropped**: a start step wrote
  `${pareto_url:+--link "Pareto front=${pareto_url}"}` into a generated script and the
  script got `--link Pareto front=https://...`, two arguments; the server exited with
  `unrecognized arguments` and the liveness check failed the run (2026-10-08,
  `workflows/dakota-openfoam`, run vocal-magpie). Build the argument before the heredoc
  with `printf -v arg -- '--link %q' "Pareto front=${url}"` and write `${arg}`.

- **`sudo` closes inherited file descriptors, so a `flock` held on fd 9 is dropped at
  `exec sudo docker logs -f`** (found in review, 2026-10-28, `workflows/gitlab`; the same
  construct is in `workflows/openproject/openproject-docker/start-template.sh`): once
  the launcher execs into the foreground log, the run directory's lock is free and a
  second run on the same directory starts a second container on the same data. Keep the
  shell that took the lock alive for the service's life (`docker logs -f … & wait $!`,
  then fail), or hold the lock in a child that is not `sudo`.
- **`$!` after `cd dir && setsid cmd ... &` is a subshell, not `cmd`** (2026-10-28, a
  hand-restarted GitLab runner survived its `cancel.sh`): bash backgrounds the whole
  `&&` list as a subshell, so the recorded pid is the subshell's and the session id to
  kill (`pkill -s`) is `cmd`'s own pid, one fork later. Background `setsid cmd &` on its
  own (then `setsid` needs no fork and `$!` is `cmd`, the session leader), `cd` before it.
- **A token on curl's command line is readable by every user of the login node** (`ps`
  shows the arguments of every process for the call's duration): pass it through a
  mode-600 file of the job with `-H @<file>` (curl 7.55+; verified 2026-11-03 on a
  STIG login node, `workflows/gitlab/lib/runners.sh`), and a secret request body with
  `--data @<file>` or `--data-urlencode name@<file>`.
- **A one-line `local` expands every word before it assigns any of them** (2026-11-03,
  `workflows/gitlab/lib/runners.sh`): `local kind=$1 file="dir/${kind}.token"` names the
  file `dir/.token`, because `${kind}` is expanded while `kind` is still unset (the
  words of `local` are ordinary command arguments). Two runners then shared one token
  file and the second was reported "already registered" as the first. Use `$1` in the
  same line, or a second `local` line.
- **bash 5.1 reads a bare `case` inside `$( )` as the keyword** and fails the whole script
  at parse time with `unexpected EOF while looking for matching` (gcptest, bash 5.1.8,
  2026-10-16: `echo "$(list_times case)"` broke a test driver; `case/log.x` as a path is
  fine, the bare word is not). Write `./case` or `case/`. A function named like a
  builtin (`times`) has the same effect inside `$( )`. macOS bash 3.2 accepts both, so
  `bash -n` locally proves nothing: run it on the target.

- **`wait -n <pid>...` ignores its pids on bash before 5.1** (EL8 ships 4.4) and returns
  when any background job ends: on PPAN a kasmvnc desktop tore itself down the moment its
  endpoint registered because the xterm loop had died (2026-10-19, run test-00128). To end
  a service when one of several processes exits, poll them (`while kill -0 $a && kill -0 $b;
  do sleep 5; done`, under `set +x`): `workflows/kasmvnc/kasmvnc-singularity/start-template.sh`.

## Software, sites and figures

- **A deterministic optimizer replays a failed generation identically**, so "no results
  → re-propose the same points" can never recover from a solver failure: two designs of
  one generation diverged (SIGFPE) on the compute nodes while converging on the login node,
  and the loop ended FAILED after re-proposing them once. Record evidence that a case *ran*
  (`exit_code` written by the case script) and feed ran-and-failed points back as FAIL;
  reserve the re-propose path for generations with no evidence of running at all
  (`workflows/dakota/app/optimizer.py`, verified 2026-09-30).
- **A site module may only point at the software.** `module load openfoam/Intel/v2512` on
  Nautilus loads the Intel compilers and OpenMPI 5.0.1, sets `foamDotFile` and prints
  "Issue the command source $foamDotFile": nothing of OpenFOAM is on PATH until that
  `source`, so the form's environment commands are two lines. `module show <mod>` tells
  in advance (a `setenv foamDotFile`, no `prepend-path PATH`). The check in
  `tools/utils/prepare-env.sh` caught it ("blockMesh not found on PATH") but only inside
  each worker; the loop now makes both checks in its own preprocessing, so a wrong
  snippet fails the run in seconds with the tools' own output instead of after a
  re-proposed generation. The same Tcl modulefile aborts in a shell without `SHELL`
  (`Module ERROR: no such variable ... ::env(SHELL)`, seen under `env -i`).
- **Pin the installer together with an exported conda environment** (`workflows/marimo`,
  2026-10-06): an env file exported from a Miniforge base pins `conda`, `mamba` and
  `python`, so applying it on top of a newer Miniforge means downgrading what the installer
  just shipped. `tools/utils/miniforge.sh` honours `MINIFORGE_URL`; the controller sets it
  to the release the file was exported from (the tag `releases/latest` redirected to at
  export time) before `miniforge_bootstrap`, and leaves it unset for `latest` and pasted
  environments. A `conda install` into base may also bump `conda` itself (26.7.2 → 26.7.3
  seen), so the export can legitimately differ from the installer's own version.
- **pvpython backend selection and exit hangs** (ParaView 6.1.1 on a cloud cluster, 2026-10-08) are in
  [software/paraview.md](software/paraview.md): name the OSMesa window with
  `VTK_DEFAULT_OPENGL_WINDOW`, end the script with `os._exit()`, bound the run with `timeout`
  and judge completeness by a file written last.
- **`nvidia-smi` says `Driver/library version mismatch` and every GPU job fails** (an existing GPU server,
  2026-10-09): unattended-upgrades replaced the NVIDIA userspace (580.173 → 580.178) under the
  running kernel module. A reboot or a module reload fixes it, an admin action on a shared box:
  ask first. `fuser /dev/nvidia*` misses holders inside containers, which open their own device
  nodes; grep `/proc/*/fd` for `nvidia` instead (there: a host `dcgm-exporter` container, gdm,
  and the GPU Operator's device plugin, paused with `nvidia.com/gpu.deploy.<operand>=false`
  node labels). `workflows/physicsnemo` checks `nvidia-smi -L` first and fails with its message.
- **Ubuntu-based containers fail every TLS call on a FIPS host** (an AWS GPU cluster, 2026-10-09):
  `/proc/sys/crypto/fips_enabled` is not namespaced, so Ubuntu's OpenSSL 3 inside the NGC
  image switches to FIPS, finds no FIPS provider and `ssl.create_default_context()` raises
  `[CRYPTO] unknown error`; Python packages that touch `ssl` at import die with it. Pass
  `OPENSSL_FORCE_FIPS_MODE=0` into the container when the host's flag is 1
  (`workflows/physicsnemo/app/train-template.sh`). Hardened images like this one also
  disable squashfs: run SIFs with `--userns` (FUSE mount) there
  ([software/physicsnemo.md](software/physicsnemo.md)).
- **A hand-made SVG figure must fit its labels in the viewer's font, not in the local
  render** (2026-10-08, `workflows/doe-openfoam/thumbnails/doe-wiring.svg`): headless Firefox
  on a cloud cluster drew `font-family="Helvetica, Arial, sans-serif"` narrower than a browser
  showing the README, where a results line ran 51 px past its box. Measure each `<text>`
  with the font's advance widths (fontTools in a scratch venv; Liberation Sans has
  Helvetica's metrics, DejaVu Sans is the wide fallback) and keep it inside its `<rect>`
  with a few px to spare, wrapping or widening where it does not fit.
