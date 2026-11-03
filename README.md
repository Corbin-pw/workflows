# Parallel Works Workflows

The home of the Parallel Works / ACTIVATE platform workflows.

**One workflow = one directory** under [`workflows/`](workflows/): the variant YAMLs
(in `yamls/`), the runtime files (scripts + support files, in `app/` or an
implementation subdir — the only subtree checked out at run time), README, build
tooling, marketplace thumbnails (in `thumbnails/`) and the recorded tests (in `tests/`)
all live together. There are **no version suffixes** — every file is the latest
version; git tags version the repo.

A workflow runs code on a resource and leaves something behind, and that is its
**shape**: most serve a web app through a **`pw` endpoint** that outlives the run
([webshell](workflows/webshell/) is the smallest); a **batch job** runs to completion
and fails when it fails ([activate-batch](workflows/activate-batch/),
[benchmarks](workflows/benchmarks/), [openfoam-naca](workflows/openfoam-naca/)); a
**callable step** runs on the login node for other workflows to call
([doe](workflows/doe/), [dakota](workflows/dakota/),
[design-explorer](workflows/design-explorer/)); a **composed** workflow is a YAML with
no code of its own that calls them ([doe-openfoam](workflows/doe-openfoam/),
[dakota-openfoam](workflows/dakota-openfoam/)); `*k8s*` variants serve the same endpoint
from a pod. The shapes, their rules and their combinations: [AGENTS.md](AGENTS.md)
("Workflow shapes").

Apart from Kubernetes, they all work the same way: a controller script installs the
software into a shared directory on the login node, and the script that does the work
(a service, a batch job) is handed to the
[`script_submitter`](workflows/script_submitter/) subworkflow, which runs it on the
login node or submits it to the SLURM/PBS scheduler. Workflows call each other as
subworkflows rather than copying code.

How this repo was assembled, and where anything older lives, is recorded in
[MIGRATION.md](MIGRATION.md).

## Workflow index

| Workflow | What it does | Variants |
|---|---|---|
| [3dcs](workflows/3dcs/) | 3DCS Monte Carlo / contributor analysis split over N SLURM workers, merged and uploaded to a bucket, with node-hour metering (no endpoint) | general |
| [activate-batch](workflows/activate-batch/) | Batch job: a list of commands run on the login node or via SLURM/PBS (no endpoint) | general, hsp |
| [agent-orchestrator](workflows/agent-orchestrator/) | Multi-agent orchestrator service | general |
| [app-testbed](workflows/app-testbed/) | Multi-site client-server pattern: a placeholder server behind a fixed endpoint, workers on other sites through SSH tunnels (login node or SLURM/PBS job) | general |
| [benchmarks](workflows/benchmarks/) | MPI and file system benchmarks: IMB-MPI1 PingPong and Alltoall, IOR, mdtest, one per run as a SLURM/PBS job, with the figures as outputs | general, hsp, noaa |
| [burst-render-demo](workflows/burst-render-demo/) | Multi-site burst demo: Mandelbrot tiles rendered on N sites in parallel, assembled live in a dashboard | general, hsp, noaa |
| [cwl-mpi-hello-world](workflows/cwl-mpi-hello-world/) | CWL demo: an MPI Hello World compiled and run as a SLURM job, submitted and monitored by cwltool on the login node (no endpoint) | general |
| [dakota](workflows/dakota/) | One Dakota optimizer step: reads the last generation's results and proposes the next batch of designs or ends the study, for any evaluator (no endpoint) | general |
| [dakota-openfoam](workflows/dakota-openfoam/) | NACA airfoil shape optimization as a loop of `dakota` and `openfoam-naca` calls, with Design Explorer over the study as an endpoint | general-naca, hsp-naca, noaa-naca (+ the `iteration-naca*` YAMLs the loop calls) |
| [dask-slurm](workflows/dask-slurm/) | Dask cluster on SLURM: adaptive dask-jobqueue workers, the Dask dashboard as endpoint, demo workloads | general, hsp, noaa |
| [design-explorer](workflows/design-explorer/) | Design Explorer's parallel coordinates over a design study, any directory of evaluated cases (`params.in`, `results.out`, images), such as a doe-openfoam or dakota-openfoam run: inputs and outputs as brushable axes, each design's images as thumbnails | general |
| [doe](workflows/doe/) | Design of experiments sampler (Latin hypercube, Sobol, random, full factorial, one at a time, or your own cases as CSV): one `params.in` case directory per design, for any evaluator (no endpoint) | general |
| [doe-openfoam](workflows/doe-openfoam/) | Design of experiments over the NACA airfoil case (Latin hypercube, Sobol, random, full factorial, one at a time, or your own cases as CSV): every design an `openfoam-naca` call in parallel, the results as a table and, with images on, Design Explorer over the study as an endpoint | general, hsp, noaa |
| [filebrowser](workflows/filebrowser/) | File Browser web file manager (Docker) | general |
| [gitlab](workflows/gitlab/) | Self-hosted GitLab (the official image rebuilt to run as the user under Singularity, or as root in Docker) on a pinned subdomain, with Sign in with ACTIVATE through the platform's OpenID Connect provider and CI/CD runners on the cluster: a shell runner on the service host and a SLURM runner through Jacamar CI, the owner's for a group of theirs, and every other user's own through the workflow's runner mode | general, hsp |
| [grafana-prometheus](workflows/grafana-prometheus/) | Grafana over Prometheus (Docker): the service node's metrics from node-exporter, its GPUs from dcgm-exporter with the GPU dashboard provisioned, extra scrape targets and, on request, the platform agent's experimental exporter | general |
| [h2o](workflows/h2o/) | H2O-3 node with its Flow UI | general, hsp, noaa |
| [hermes-agent](workflows/hermes-agent/) | Hermes agent with auth/TCP proxies | general |
| [hpc_status](workflows/hpc_status/) | HPC Status Monitor: fleet status, topology, queues, quota and storage dashboard over every cluster `pw` reaches, at a stable `status-<user>` address | general, hsp, noaa |
| [jupyter](workflows/jupyter/) | Jupyter Notebook (classic) | general, emed, noaa |
| [jupyterlab](workflows/jupyterlab/) | JupyterLab | general, emed, hsp, noaa, general_k8s, k8s |
| [kasmvnc](workflows/kasmvnc/) | KasmVNC desktop (Singularity) | general, general_rstudio, emed, emed_{rstudio, matlab, firefox, fsl, schrodinger, vmd}, hsp, noaa, noaa_rstudio, general_k8s, k8s |
| [langflow-singularity](workflows/langflow-singularity/) | Langflow (Singularity) | hsp |
| [librechat](workflows/librechat/) | LibreChat (+ `-all` stacks with manager & Langflow) | general, hsp, general-all, hsp-all |
| [lite-agent](workflows/lite-agent/) | Lightweight agent worker | general |
| [marimo](workflows/marimo/) | marimo notebooks (edit or run mode) | general, hsp, noaa |
| [metabase](workflows/metabase/) | Metabase BI server (Docker) on a compute cluster or Kubernetes | general, general_k8s |
| [mlflow](workflows/mlflow/) | MLflow tracking server (UI + REST API) on a compute cluster or Kubernetes | general, hsp, noaa, k8s, general_k8s |
| [monte-carlo-pricing](workflows/monte-carlo-pricing/) | Multi-site Monte Carlo option pricing (Asian, European, barrier): batches of paths simulated on N sites in parallel, the price converging live in a dashboard | general |
| [n8n](workflows/n8n/) | n8n automation (Docker/Singularity) | general, emed, hsp, noaa |
| [ollama](workflows/ollama/) | Ollama GGUF model server (native/container) | general, hsp, noaa |
| [ollama-openwebui](workflows/ollama-openwebui/) | Ollama + OpenWebUI on Kubernetes | k8s |
| [omniverse](workflows/omniverse/) | NVIDIA Omniverse through Isaac Sim (Singularity or Docker) on a GPU node: `-render` runs an example (a pyramid of blocks, a wall prefractured with the Blast SDK or a mesh of yours, your scene, a physics-only run) with PhysX or Newton and serves the frames or the poses as a page; `-build` assembles a USD scene from meshes and robots (batch); `-desktop` opens Isaac Sim's window in a KasmVNC desktop | general-render, hsp-render, noaa-render, general-build, hsp-build, noaa-build, general-desktop |
| [open-notebook](workflows/open-notebook/) | Open Notebook (Docker) | general |
| [openfoam-naca](workflows/openfoam-naca/) | One OpenFOAM case of a NACA 4-digit airfoil: C-grid mesh, `simpleFoam`, lift and drag coefficients, optional ParaView images; the evaluator of doe-openfoam and dakota-openfoam. The `*-restart` variants resubmit a long case from its checkpoints until it completes: the example of checkpoints, a resumable run script and a retried subworkflow step for a simulation tool of your own (no endpoint) | general, hsp, noaa, general-restart, hsp-restart, noaa-restart |
| [openproject](workflows/openproject/) | OpenProject project management (Singularity from a prebuilt SIF as your user, or the all-in-one Docker image) on a pinned subdomain, with Sign in with ACTIVATE through the platform's OpenID Connect provider | general, hsp, noaa |
| [openvscode](workflows/openvscode/) | OpenVSCode Server | general, emed, hsp, noaa, general_k8s, k8s |
| [pgadmin4](workflows/pgadmin4/) | pgAdmin 4 web client for PostgreSQL (Docker) on a compute cluster or Kubernetes, with a server registered from the form | general, general_k8s |
| [physicsnemo](workflows/physicsnemo/) | NVIDIA PhysicsNeMo training in the NGC container (Docker or Singularity, GPU or CPU) on the login node or as a SLURM/PBS job: Darcy FNO, Darcy Transolver, LDC PINN or your own script, with TensorBoard live as an endpoint | general |
| [postgres](workflows/postgres/) | PostgreSQL server (Docker) on a compute cluster or Kubernetes, with the pgweb SQL client as the endpoint and the database reachable over TCP | general, general_k8s |
| [probe](workflows/probe/) | PROBE: runs a platform's workflow tests from their definitions repository ([probe-tests-activate-parallel-works](https://github.com/parallelworks/probe-tests-activate-parallel-works) for activate.parallel.works), records the results in a bucket or a directory on the host and serves the results dashboards | general, general_run_tests (batch, no endpoint) |
| [pydio-cells](workflows/pydio-cells/) | Pydio Cells file sharing and collaboration platform with MySQL (Docker), a host directory as its Data Directory workspace | general |
| [rag-service](workflows/rag-service/) | RAG search/index service | general |
| [rag-vllm](workflows/rag-vllm/) | vLLM inference server + optional RAG stack | general, hsp, noaa |
| [ray-cluster](workflows/ray-cluster/) | Multi-site Ray cluster: head and live dashboard on one resource, SLURM/PBS/SSH workers on any others | general, hsp, noaa, general_add_worker, hsp_add_worker, noaa_add_worker |
| [streamlit](workflows/streamlit/) | Streamlit apps (Singularity) | general, hsp |
| [vncserver](workflows/vncserver/) | Host desktop (KasmVNC, no container) | emed, emed_{rstudio, matlab, firefox, fsl, schrodinger, vmd} |
| [webshell](workflows/webshell/) | Web terminal (ttyd) | general, noaa |

`librechat-singularity-manager` is a component of the librechat `-all` workflows
([workflows/librechat/librechat-singularity-manager/](workflows/librechat/librechat-singularity-manager/)).

**Shared subworkflows** (referenced by the workflow YAMLs via
`uses: github/parallelworks/workflows@canary` + `$yaml:`):

- [workflows/script_submitter/v3.6/](workflows/script_submitter/) — SLURM/PBS/SSH
  script submission, used by every workflow that runs a script on a cluster
- [workflows/wait_for_endpoint/](workflows/wait_for_endpoint/) — waits until an
  endpoint is listed and its URL answers, then releases the submitter; the health
  check every endpoint workflow owns

The sampler, the optimizer step, the case runner and the study page
([doe](workflows/doe/), [dakota](workflows/dakota/),
[openfoam-naca](workflows/openfoam-naca/), [design-explorer](workflows/design-explorer/))
are called the same way by the composed workflows.

**Shared tools** — [`tools/`](tools/) (`tools/oras`, `tools/utils`) are sparse-checked-out
next to `workflows/<name>` at runtime; scripts reference them as `tools/...` relative
to the run directory.

**Tests** — each workflow's end-to-end tests live under `workflows/<name>/tests/<variant>/`;
layout, runner and results are documented in [`tools/tests/README.md`](tools/tests/README.md).

**Tutorials** — [`tutorials/`](tutorials/) are staged, runnable lessons that build a
small demo app ([`demo-app/`](tutorials/demo-app/)) into a full workflow:
[`endpoint-workflows/`](tutorials/endpoint-workflows/) (the current `pw endpoints`
pattern, stages 1–7 incl. matrix fan-out, first-start-wins, and failover) and
[`session-workflows-hsp/`](tutorials/session-workflows-hsp/) (the same journey, HSP-flavored,
in the older form the upgrade playbook converts). [`optimization/`](tutorials/optimization/)
builds an iterative loop — propose designs, evaluate them in parallel, decide, repeat
until convergence — behind a file contract that `dakota-openfoam` fills with real tools.
[`if-conditions/`](tutorials/if-conditions/)
is a short standalone lesson on the `if:` status functions (`success()`, `failure()`,
`cancelled()`, `always()` and their negations) on steps and on jobs, with what replaces
the keywords ACTIVATE removed.

## Variants

`general` targets standard cloud/on-prem SLURM & PBS clusters. `emed`, `hsp`, and
`noaa` are the variants for the `cluster.einsteinmed.edu`, `activate.hpc.mil` and
`noaa.parallel.works` platforms, with their schedulers, defaults, and network
constraints; they also run on the cloud clusters of `activate.parallel.works`, which is
how they are tested (`tests/hsp/`, `tests/noaa/`). `*k8s*` variants
target Kubernetes clusters ([.claude/skills/activate-workflows/references/k8s-workflows.md](.claude/skills/activate-workflows/references/k8s-workflows.md)).

## Running a workflow

From a machine with the [`pw` CLI](https://parallelworks.com/docs/cli) authenticated:

```bash
pw workflows run "$PWD/workflows/webshell/yamls/general.yaml" -i '{"resource":"<cluster-name>","cluster":{"scheduler":false}}'
```

(Pass the YAML as an **absolute path** — the CLI parses relative paths as git hosts.)

When testing a workflow, also verify cleanup: cancel a run mid-flight and confirm
nothing is left behind (processes, scheduler jobs, containers), and delete test
endpoints when done — see [DeveloperGuide.md](DeveloperGuide.md).

What the run leaves behind depends on the shape: an endpoint workflow registers a
**`pw` endpoint** (`pw endpoints list`) that keeps serving after the run completes,
until `pw endpoints delete <name>`; a batch workflow runs its job to completion and
fails when it fails; a Kubernetes run stays alive and is torn down by cancelling it.
Note that workflow YAMLs pull this repo from GitHub at runtime
(`parallelworks/checkout` + subworkflow `uses:`), so local YAML edits only take full
effect once pushed to the referenced branch (**canary**).

## Developing

- [DeveloperGuide.md](DeveloperGuide.md) — how to add or change a workflow
- [AGENTS.md](AGENTS.md) — repo conventions and the workflow shapes (also read by AI agents)
- [docs/ai-workflow-development/](docs/ai-workflow-development/) — building workflows
  with AI agents; the `activate-workflows` Claude Code skill lives at
  [.claude/skills/activate-workflows/](.claude/skills/activate-workflows/)
- [app-ui.md](.claude/skills/activate-workflows/references/app-ui.md) — the UI of a
  workflow's own web app, in the platform's look: the theme contract of
  [`@parallelworks/ui`](https://github.com/parallelworks/foundation), vendored with
  `tools/ui/sync-theme.sh`
- [MIGRATION.md](MIGRATION.md) — the consolidation map: where every file came from,
  what stayed behind, and why
- Official platform docs:
  [building workflows](https://parallelworks.com/docs/run/workflows/building-workflows)
  ([YAML fields](https://parallelworks.com/docs/run/workflows/building-workflows/yaml-fields) ·
  [inputs & expressions](https://parallelworks.com/docs/run/workflows/building-workflows/inputs-and-expressions) ·
  [actions](https://parallelworks.com/docs/run/workflows/building-workflows/actions)) ·
  [endpoint sessions](https://parallelworks.com/docs/run/sessions/endpoints) ·
  [`pw endpoints` CLI](https://parallelworks.com/docs/cli/pw/endpoints)
