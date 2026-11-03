################################################################################
# GitLab CI runners, shared by both modes of the workflow
#
# Purpose: Register the shell and SLURM runners with a GitLab through its API,
#          write gitlab-runner's config.toml (and Jacamar's jacamar.toml), start
#          gitlab-runner in a session of its own and write the cancel.sh that
#          stops it. In gitlab mode the launcher (lib/launcher.sh) calls this
#          with root's token and the group it created for the owner; in runner
#          mode the start script (lib/runner-start-template.sh) calls it with
#          the user's personal access token and the project or group the user
#          named. Either way the runner runs as the user who launched the run,
#          with the run's PW_API_KEY removed from its environment: a pipeline
#          that calls pw brings its own key as a CI/CD variable.
# Runs on: Controller node
#
# Required Environment Variables (exported by the caller):
#   - runner_root: holds tokens/, config.toml, builds/, cache/, runner.log,
#     jacamar/ and jacamar.toml; the whole tree is private to the user
#   - run_dir: this job's run/ directory (runner.pid)
#   - gitlab_runner_bin, jacamar_bin, runners_shell, runners_slurm
#   - api_base: GitLab's API, http://127.0.0.1:<port>/api/v4
#   - api_host: the Host header for loopback calls (may be empty)
#   - api_token: a token with the api and create_runner scopes; may be empty
#     in runner mode on a later start, when the stored runner tokens are kept
#   - runner_type (instance_type | group_type | project_type) and
#     runner_scope_id (the group or project id; empty for instance_type)
#   - runner_url: the GitLab URL the runner polls and clones from,
#     http://127.0.0.1:<port>
################################################################################

runners_find_tool() {
    # runners_find_tool <tool> <binary>: prints the binary lib/runner-tools.sh installed,
    # in the platform's install directory or the user's own
    local base
    for base in "${service_parent_install_dir}" "${HOME}/pw/software"; do
        if [ -x "${base}/$1/current/$2" ]; then
            echo "${base}/$1/current/$2"
            return 0
        fi
    done
    echo "${service_parent_install_dir}/$1/current/$2"
}

# The token goes to curl in a file of this job (curl's -H @file), never on its
# command line, which every user of the login node can read in ps
runners_api_call() {
    # runners_api_call <method> <path> [curl args...]: sets api_status and api_body
    local method=$1 path=$2 out headers="${run_dir}/api-headers"
    shift 2
    (
        umask 077
        {
            if [ -n "${api_token}" ]; then echo "PRIVATE-TOKEN: ${api_token}"; fi
            if [ -n "${api_host}" ]; then echo "Host: ${api_host}"; fi
        } > "${headers}"
    )
    out=$(curl -s -w '\n%{http_code}' -X "${method}" -H "@${headers}" "$@" "${api_base}${path}")
    rm -f "${headers}"
    api_status=${out##*$'\n'}
    api_body=${out%$'\n'*}
}

json_get() {
    # json_get <key> reads a JSON object from stdin
    python3 -c 'import json, sys; d = json.load(sys.stdin); v = d.get(sys.argv[1], ""); print(v if v is not None else "")' "$1"
}

# The runner outlives the run like the service does and must not die with
# the endpoint's process tree by accident, so it gets a session of its own,
# which cancel.sh kills by session id
runners_write_cancel_sh() {
    cat > cancel.sh <<CANCELEOF
#!/bin/bash
if [ -s "${run_dir}/runner.pid" ]; then
    pid=\$(cat "${run_dir}/runner.pid")
    pkill -TERM -s "\${pid}" 2>/dev/null
    for i in \$(seq 1 20); do
        pgrep -s "\${pid}" >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -KILL -s "\${pid}" 2>/dev/null
fi
CANCELEOF
    chmod +x cancel.sh
}

# A stored runner is kept only while it still authenticates and still belongs
# to the scope of this run (an instance runner of an earlier version of the
# workflow, or a runner of another project, would take jobs it must not):
# any other one is removed and a new one registered
runners_scope_matches() {
    printf '%s' "${api_body}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
t, i = sys.argv[1], sys.argv[2]
if d.get("runner_type") != t:
    sys.exit(1)
if t == "instance_type":
    sys.exit(0)
owners = d.get("groups" if t == "group_type" else "projects") or []
sys.exit(0 if any(str(o.get("id")) == i for o in owners) else 1)
' "${runner_type}" "${runner_scope_id}"
}

runners_register() {
    # runners_register <kind> <run_untagged>
    local kind=$1 untagged=$2 token_file="${runner_root}/tokens/$1.token" token id
    if [ -s "${token_file}" ]; then
        api_token="" runners_api_call POST /runners/verify --data-urlencode "token@${token_file}"
        if [ "${api_status}" = "200" ]; then
            id=$(printf '%s' "${api_body}" | json_get id)
            if [ -z "${api_token}" ]; then
                echo "The ${kind} runner is already registered (runner ${id:-?}); kept as is, no token was given to check its scope"
                return 0
            fi
            runners_api_call GET "/runners/${id}"
            if [ "${api_status}" = "200" ] && runners_scope_matches; then
                echo "The ${kind} runner is already registered (runner ${id})"
                return 0
            fi
            echo "Runner ${id} (the stored ${kind} runner) is not a ${runner_type%_type} runner of ${runner_scope_id:-this instance} (HTTP ${api_status}); removing it"
            runners_api_call DELETE "/runners/${id}"
            if [ "${api_status}" != "204" ]; then
                echo "::warning::Runner ${id} was not removed (HTTP ${api_status}): delete it in GitLab"
            fi
        else
            echo "The stored ${kind} runner token is no longer valid (HTTP ${api_status}); registering again"
        fi
        rm -f "${token_file}"
    fi
    if [ -z "${api_token}" ]; then
        echo "::error title=Error::The ${kind} runner is not registered and no token was given to register it"
        return 1
    fi
    local scope=()
    case "${runner_type}" in
        group_type) scope=(--data "group_id=${runner_scope_id}") ;;
        project_type) scope=(--data "project_id=${runner_scope_id}") ;;
    esac
    runners_api_call POST /user/runners \
        --data "runner_type=${runner_type}" "${scope[@]}" \
        --data-urlencode "description=${kind} runner of $(id -un) on $(hostname) (ACTIVATE run ${PW_RUN_SLUG})" \
        --data "tag_list=${kind}" \
        --data "run_untagged=${untagged}" \
        --data "paused=false"
    token=$(printf '%s' "${api_body}" | json_get token)
    if [ "${api_status}" != "201" ] || [ -z "${token}" ]; then
        # The body of a success carries the token, so only the message is shown
        echo "::error title=Error::Could not register the ${kind} runner (HTTP ${api_status}): $(printf '%s' "${api_body}" | json_get message)"
        return 1
    fi
    (
        umask 077
        printf '%s' "${token}" > "${token_file}"
    )
    echo "Registered the ${kind} runner (runner $(printf '%s' "${api_body}" | json_get id))"
}

runners_block() {
    # runners_block <kind> <executor>
    local kind=$1 executor=$2
    cat <<TOMLEOF

[[runners]]
  name = "${kind} runner of $(id -un) on $(hostname)"
  url = "${runner_url}/"
  clone_url = "${runner_url}"
  token = "$(cat "${runner_root}/tokens/${kind}.token")"
  executor = "${executor}"
  shell = "bash"
  builds_dir = "${runner_root}/builds/${kind}"
  cache_dir = "${runner_root}/cache/${kind}"
TOMLEOF
}

# runners_setup: registers the runners the form asked for, writes their
# configuration (rewritten on every start because the GitLab port changes
# with the endpoint) and starts gitlab-runner. Prints the kinds started in
# runners_started. Nothing here enters the trace: tokens are written
runners_setup() {
    set +x
    runners_started=""
    mkdir -p "${runner_root}/tokens" "${runner_root}/builds" "${runner_root}/cache"
    # Checkouts, caches and the tokens are the user's alone, whatever the umask
    chmod 700 "${runner_root}" "${runner_root}/tokens"
    if [ "${runners_shell}" = "true" ]; then
        runners_register shell true || return 1
        runners_started="${runners_started} shell"
    fi
    if [ "${runners_slurm}" = "true" ]; then
        runners_register slurm false || return 1
        runners_started="${runners_started} slurm"
    fi
    if [ -z "${runners_started}" ]; then
        set -x
        return 0
    fi
    (
        umask 077
        {
            echo "concurrent = 4"
            echo "check_interval = 3"
            if [ "${runners_shell}" = "true" ]; then
                runners_block shell shell
            fi
            if [ "${runners_slurm}" = "true" ]; then
                runners_block slurm custom
                # Plain jacamar (no jacamar-auth in front) refuses to run
                # without --no-auth; every stage takes it
                cat <<TOMLEOF
  [runners.custom]
    config_exec = "${jacamar_bin}"
    config_args = ["--no-auth", "config", "--configuration", "${runner_root}/jacamar.toml"]
    prepare_exec = "${jacamar_bin}"
    prepare_args = ["--no-auth", "prepare"]
    run_exec = "${jacamar_bin}"
    run_args = ["--no-auth", "run"]
    cleanup_exec = "${jacamar_bin}"
    cleanup_args = ["--no-auth", "cleanup", "--configuration", "${runner_root}/jacamar.toml"]
    graceful_kill_timeout = 600
    force_kill_timeout = 300
TOMLEOF
            fi
        } > "${runner_root}/config.toml"
    )
    if [ "${runners_slurm}" = "true" ]; then
        mkdir -p "${runner_root}/jacamar"
        chmod 700 "${runner_root}/jacamar"
        # Jacamar runs the stages it keeps on this host (sources, artifacts,
        # cache) as `env -i bash --login` scripts, so the runner's
        # environment never reaches them, and the artifact and cache stages
        # look gitlab-runner up by name ("Missing gitlab-runner. Uploading
        # artifacts is disabled." otherwise): the binary is linked into
        # ~/bin, which the login profile puts on the PATH. Jacamar's
        # user_bash_env is no alternative: it is passed to env -i as is,
        # so a PATH set there replaces the profile's (verified)
        mkdir -p "${HOME}/bin"
        ln -sfn "${gitlab_runner_bin}" "${HOME}/bin/gitlab-runner"
        if ! env -i HOME="${HOME}" USER="$(id -un)" /bin/bash --login -c 'command -v gitlab-runner' >/dev/null 2>&1; then
            echo "::warning::A login shell on $(hostname) does not find ~/bin/gitlab-runner on its PATH: jobs of the SLURM runner cannot upload artifacts or caches. Add \$HOME/bin to the PATH in your shell profile"
        fi
        # Jacamar verifies the job's id token against GitLab's keys; fetched
        # through the public URL they come back as the platform's sign-in page
        cat > "${runner_root}/jacamar.toml" <<TOMLEOF
[general]
  executor = "slurm"
  data_dir = "${runner_root}/jacamar"
  gitlab_server = "${runner_url}"
TOMLEOF
    fi
    # The runner's environment is the shell runner's jobs' environment: the
    # binary's directory joins the PATH for the artifact and cache stages, and
    # the run's API key, which dies with the run and belongs to whoever
    # launched it, never reaches a job: a pipeline that calls pw sets
    # PW_API_KEY as a masked CI/CD variable of its own
    PATH="${gitlab_runner_bin%/*}:${PATH}" setsid nohup env -u PW_API_KEY "${gitlab_runner_bin}" run \
        --config "${runner_root}/config.toml" \
        --working-directory "${runner_root}" \
        > "${runner_root}/runner.log" 2>&1 < /dev/null &
    echo $! > "${run_dir}/runner.pid"
    sleep 3
    if ! kill -0 "$(cat "${run_dir}/runner.pid")" 2>/dev/null; then
        tail -n 30 "${runner_root}/runner.log"
        echo "::error title=Error::gitlab-runner exited right after starting (log above)"
        set -x
        return 1
    fi
    echo "::notice::CI runners started:${runners_started} (log: ${runner_root}/runner.log)"
    set -x
}
