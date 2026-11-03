################################################################################
# GitLab runner starter (runner mode)
#
# Purpose: Add the user's own CI runners to a GitLab another user started on
#          this login node with this workflow, so that the user's pipelines
#          run as the user, with the user's cluster account and credentials,
#          and never as the GitLab's owner. The GitLab is reached on the
#          host's loopback (the platform's proxy blocks git and the runner):
#          this script asks the GitLab, through its public address with the
#          run's key, which loopback port it listens on and which uid owns it,
#          and every connection the runner makes goes through a forwarder of
#          this run that first checks, in /proc/net/tcp, that the socket at
#          the other end belongs to that uid, so a process of another user
#          that takes the port over later never sees a runner token or a
#          job's variables. The runners are registered with the user's
#          personal access token as runners of the project or group the user
#          named, so only that project's or group's pipelines run here; their
#          tokens are kept in the runner directory and found again by a later
#          start. The endpoint serves a status page of the runners.
# Runs on: Controller node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name)
#   - runners_gitlab_url: the GitLab's address, https://<subdomain>.<sessions domain>
#   - runners_path: the project or group the runners belong to
#   - runners_token_file: the personal access token the form carried (may be empty)
#   - runners_rundir: holds tokens/, config.toml, builds/, cache/ and runner.log
#   - runners_shell, runners_slurm: which CI runners to start
#   - service_parent_install_dir: holds gitlab-runner/current and
#     jacamar-ci/current, installed by lib/runner-controller.sh when needed
#   - PW_API_KEY (runtime env): the run's key, to read the GitLab's loopback
#     port through its public address
################################################################################

set -x
set -o pipefail

gitlab_lib="${PW_PARENT_JOB_DIR}/workflows/gitlab/lib"
source "${gitlab_lib}/runners.sh"

if [ -z "${runners_rundir}" ]; then
    runners_rundir=${HOME}/gitlab-runner
fi
if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
export runner_root
runner_root=$(realpath -m "${runners_rundir}")
export gitlab_runner_bin=$(runners_find_tool gitlab-runner gitlab-runner)
export jacamar_bin=$(runners_find_tool jacamar-ci jacamar)
if ! [ -x "${gitlab_runner_bin}" ]; then
    echo "::error title=Error::gitlab-runner is not installed at ${gitlab_runner_bin} (the controller installs it)"
    exit 1
fi
if [ "${runners_slurm}" = "true" ] && ! [ -x "${jacamar_bin}" ]; then
    echo "::error title=Error::Jacamar CI is not installed at ${jacamar_bin} (the controller installs it)"
    exit 1
fi
for tool in curl flock python3; do
    if ! command -v ${tool} >/dev/null 2>&1; then
        echo "::error title=Error::${tool} is not installed on $(hostname)"
        exit 1
    fi
done
mkdir -p "${runner_root}"
chmod 700 "${runner_root}"

# Files of this job, not of the runner directory: the runner's and the
# forwarder's pids and logs, the status page's data
export run_dir="${PWD}/run"
mkdir -p "${run_dir}"

# Neither the runner (a session of its own) nor the forwarder (a child of
# this script, which the submitter's process-group kill may miss) is in the
# endpoint's process tree: cancel.sh, run by the cleanup trap, stops both
runners_write_cancel_sh
cat >> cancel.sh <<CANCELEOF
if [ -s "${run_dir}/forward.pid" ]; then
    kill "\$(cat "${run_dir}/forward.pid")" 2>/dev/null
fi
CANCELEOF

# One runner process per runner directory: two would take the same jobs
exec 9>"${runner_root}/.lock"
if ! flock -w 10 9; then
    echo "::error title=Error::${runner_root} is in use by another run of these runners; delete that session first or choose another runner directory"
    exit 75
fi

gitlab_url=${runners_gitlab_url%/}
gitlab_host=${gitlab_url#https://}
gitlab_host=${gitlab_host%%[/:?]*}
platform_host=${PW_PLATFORM_HOST#https://}
platform_host=${platform_host#http://}
platform_host=${platform_host%%/*}
# A login node that resolves the platform host but not the sessions domain
# reaches the endpoint through the platform's front end (wait_for_endpoint
# does the same)
connect_to=""
if command -v getent >/dev/null 2>&1 && ! getent hosts "${gitlab_host}" >/dev/null 2>&1 \
        && [ -n "${platform_host}" ] && getent hosts "${platform_host}" >/dev/null 2>&1; then
    connect_to="${gitlab_host}:443:${platform_host}:443"
    echo "::notice::${gitlab_host} does not resolve here; reaching it through ${platform_host}"
fi

# The GitLab's launcher serves its loopback port, the uid it runs as and its
# host on this route, behind the platform's sign-in: the run's key answers
# for the user, whom the GitLab's session must have been shared with. The
# key stays out of the trace
echo "Asking ${gitlab_url} where it listens"
set +x
if [ -z "${PW_API_KEY}" ]; then
    echo "::error title=Error::PW_API_KEY is not set; ${gitlab_url} cannot be asked where it listens"
    exit 1
fi
(
    umask 077
    echo "Authorization: Bearer ${PW_API_KEY}" > "${run_dir}/host-headers"
)
resp=$(curl -s -w '\n%{http_code}' --max-time 30 ${connect_to:+--connect-to "${connect_to}"} \
    -H "@${run_dir}/host-headers" "${gitlab_url}/-/activate/host")
rm -f "${run_dir}/host-headers"
set -x
host_status=${resp##*$'\n'}
host_body=${resp%$'\n'*}
if [ "${host_status}" != "200" ]; then
    echo "::error title=Error::${gitlab_url}/-/activate/host answered HTTP ${host_status:-nothing}: the address must be a GitLab this workflow serves, its session shared with you (ask whoever started it), and its run must have completed"
    exit 1
fi
read -r gitlab_port gitlab_uid gitlab_node <<< "$(printf '%s' "${host_body}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(int(d["port"]), int(d["uid"]), d.get("host", ""))
except Exception:
    print("")
')"
if [ -z "${gitlab_port}" ] || [ -z "${gitlab_uid}" ]; then
    echo "::error title=Error::${gitlab_url}/-/activate/host did not answer with a port and a uid (is it a GitLab of this workflow?): ${host_body}"
    exit 1
fi
if [ "${gitlab_node}" != "$(hostname)" ]; then
    echo "::error title=Error::${gitlab_url} runs on the login node ${gitlab_node:-(unknown)}, not on $(hostname): the runners reach it on that node's loopback, so add them from a run that lands there"
    exit 1
fi
echo "::notice::${gitlab_url} listens on 127.0.0.1:${gitlab_port} of $(hostname) as uid ${gitlab_uid}"

# Nothing but that uid (or root, for a port Docker publishes) may hold the port
listener_uid=$(python3 "${gitlab_lib}/runner-service.py" listener-uid "${gitlab_port}")
if [ -z "${listener_uid}" ]; then
    echo "::error title=Error::Nothing listens on 127.0.0.1:${gitlab_port}; the GitLab at ${gitlab_url} may be restarting. Try again once it answers"
    exit 1
fi
if [ "${listener_uid}" != "${gitlab_uid}" ] && [ "${listener_uid}" != "0" ]; then
    echo "::error title=Error::127.0.0.1:${gitlab_port} is held by uid ${listener_uid}, not by the GitLab's uid ${gitlab_uid}: the GitLab moved or stopped. Try again once ${gitlab_url} answers"
    exit 1
fi

# The forwarder: the runner's one way to the GitLab. It belongs to this
# script's process group and is killed with it, or by cancel.sh
forward_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 "${gitlab_lib}/runner-service.py" forward \
    --port "${forward_port}" --gitlab-port "${gitlab_port}" --gitlab-uid "${gitlab_uid}" \
    --log "${run_dir}/forward.log" &
echo $! > "${run_dir}/forward.pid"
for i in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${forward_port}/" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$(cat "${run_dir}/forward.pid")" 2>/dev/null; then
        cat "${run_dir}/forward.log" 2>/dev/null
        echo "::error title=Error::The forwarder to 127.0.0.1:${gitlab_port} exited (its log is above)"
        exit 1
    fi
    sleep 0.5
done
runner_url="http://127.0.0.1:${forward_port}"
export runner_url

# The GitLab itself, through the forwarder (the probe header passes the
# gate its launcher keeps on the sign-in page while it sets up)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Host: ${gitlab_host}" -H "X-Activate-Probe: 1" "${runner_url}/users/sign_in")
if [ "${code}" != "200" ]; then
    tail -n 5 "${run_dir}/forward.log" 2>/dev/null
    echo "::error title=Error::The GitLab on 127.0.0.1:${gitlab_port} answers HTTP ${code:-nothing} to its sign-in page (its forwarder's log is above)"
    exit 1
fi

# The token (never traced) and the project or group it names; without a token
# the stored runners are kept and the scope they were registered for is shown
export api_base="${runner_url}/api/v4" api_host="${gitlab_host}"
export api_token="" runner_type="" runner_scope_id=""
runner_scope=""
set +x
if [ -s "${runners_token_file}" ]; then
    api_token=$(tr -d '\n\r' < "${runners_token_file}")
fi
if [ -n "${api_token}" ]; then
    runners_api_call GET /user
    if [ "${api_status}" != "200" ]; then
        echo "::error title=Error::${gitlab_url} does not accept the personal access token (HTTP ${api_status}): it needs the api and create_runner scopes and must not have expired"
        exit 1
    fi
    gitlab_user=$(printf '%s' "${api_body}" | json_get username)
    encoded_path=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${runners_path}")
    runners_api_call GET "/projects/${encoded_path}"
    if [ "${api_status}" = "200" ]; then
        runner_type=project_type
        runner_scope="project"
    else
        runners_api_call GET "/groups/${encoded_path}"
        if [ "${api_status}" = "200" ]; then
            runner_type=group_type
            runner_scope="group"
        else
            echo "::error title=Error::${runners_path} is neither a project nor a group that ${gitlab_user} can see on ${gitlab_url} (HTTP ${api_status}): give the full path, namespace included (jane/hpc-pipeline, not hpc-pipeline), as it follows the GitLab address in the browser"
            exit 1
        fi
    fi
    runner_scope_id=$(printf '%s' "${api_body}" | json_get id)
    (
        umask 077
        printf '%s %s %s\n' "${runner_scope}" "${runner_scope_id}" "${runners_path}" > "${runner_root}/scope"
    )
    echo "::notice::Registering the runners as ${gitlab_user} for ${runner_scope} ${runners_path} (${runner_scope_id})"
elif [ -s "${runner_root}/scope" ]; then
    read -r runner_scope runner_scope_id runners_path < "${runner_root}/scope"
    echo "::notice::No token given: the runners registered in ${runner_root} for ${runner_scope} ${runners_path} are kept"
fi
set -x

# Registers (or finds) the runners, writes their configuration and starts them
if ! runners_setup; then
    echo "::error title=Error::The runners were not started (above)"
    exit 1
fi

# What the status page shows
GITLAB_URL="${gitlab_url}" GITLAB_HOST="${gitlab_host}" GITLAB_PORT="${gitlab_port}" GITLAB_UID="${gitlab_uid}" \
    FORWARD_PORT="${forward_port}" RUNNER_USER="$(id -un)" RUNNER_HOST="$(hostname)" RUNNER_SCOPE="${runner_scope}" \
    RUNNER_PATH="${runners_path}" RUNNER_ROOT="${runner_root}" RUN_DIR="${run_dir}" RUN_SLUG="${PW_RUN_SLUG}" \
    RUNNERS_SHELL="${runners_shell}" RUNNERS_SLURM="${runners_slurm}" \
    python3 - "${run_dir}/status.json" <<'STATUSEOF'
import json, os, sys, time
e = os.environ
runners = []
if e["RUNNERS_SHELL"] == "true":
    runners.append({"kind": "shell", "executor": "shell", "tags": ["shell"], "untagged": True})
if e["RUNNERS_SLURM"] == "true":
    runners.append({"kind": "slurm", "executor": "custom (Jacamar CI, sbatch)", "tags": ["slurm"], "untagged": False})
with open(sys.argv[1], "w") as f:
    json.dump({
        "gitlab_url": e["GITLAB_URL"], "gitlab_host": e["GITLAB_HOST"], "gitlab_port": int(e["GITLAB_PORT"]),
        "gitlab_uid": int(e["GITLAB_UID"]), "forward_port": int(e["FORWARD_PORT"]),
        "user": e["RUNNER_USER"], "host": e["RUNNER_HOST"], "scope": e["RUNNER_SCOPE"], "path": e["RUNNER_PATH"],
        "runner_root": e["RUNNER_ROOT"], "run_dir": e["RUN_DIR"], "runners": runners,
        "run_slug": e["RUN_SLUG"], "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, f)
STATUSEOF

echo "::notice::Pipelines of ${runner_scope:-the registered scope} ${runners_path} now run on $(hostname) as $(id -un); a job that calls pw needs PW_API_KEY as a CI/CD variable of the project"
echo "::group::Serving the runner status page"

# The status page keeps the endpoint alive for the life of the runners; the
# forwarder and the runner die with it (cancel.sh)
pw endpoints run ${pw_endpoints_args} -- python3 "${gitlab_lib}/runner-service.py" status \
    --port {port} --state "${run_dir}/status.json" --web "${gitlab_lib}/web"
status=$?
if [ "${status}" -eq 0 ]; then
    echo "::endgroup::"
    exit 0
fi
# pw endpoints run blocks for the life of the service, so it also returns
# non-zero when the workflow cancels this job after a successful launch,
# which is how wait_for_endpoint releases the run; a launch that never
# registered its endpoint is a real failure
served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
    echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
    exit 0
fi
echo "::error title=Error::pw endpoints command failed"
exit 1
