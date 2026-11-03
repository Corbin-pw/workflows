set -o pipefail

################################################################################
# GitLab runner controller (runner mode)
#
# Purpose: Check the form's values for a run that adds the user's own CI
#          runners to a GitLab another user started on this cluster, and
#          install the runner tools (lib/runner-tools.sh). No container, no
#          image: the GitLab is somebody else's.
# Runs on: Controller node
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - runners_gitlab_url: the GitLab's address, https://<subdomain>.<sessions domain>
#   - runners_path: the project or group the runners belong to
#   - runners_token_file: the personal access token the form carried (may be empty)
#   - runners_rundir: holds the runners' tokens, configuration, builds and cache
#   - runners_shell / runners_slurm: which CI runners to register
#   - service_parent_install_dir: where gitlab-runner and jacamar are installed
################################################################################

if [ "${runners_shell}" != "true" ] && [ "${runners_slurm}" != "true" ]; then
    echo "::error title=Error::No runner to add: turn on the shell runner, the SLURM runner or both"
    exit 1
fi

case "${runners_gitlab_url}" in
    https://*.*) ;;
    *)
        echo "::error title=Error::The GitLab address must be the https://<subdomain>.<sessions domain> address of a GitLab served on this platform: '${runners_gitlab_url}'"
        exit 1
        ;;
esac

# A project path is <namespace>/<project>, possibly nested; a group path has
# no slash or is a subgroup's
if [ -z "${runners_path}" ] || ! printf '%s' "${runners_path}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)*$'; then
    echo "::error title=Error::The project or group must be a GitLab path such as jane/hpc-pipeline or team-a: '${runners_path}'"
    exit 1
fi

if [ -z "${runners_rundir}" ]; then
    runners_rundir=${HOME}/gitlab-runner
fi
runner_root=$(realpath -m "${runners_rundir}")
mkdir -p "${runner_root}"
if ! [ -w "${runner_root}" ]; then
    echo "::error title=Error::The runner directory ${runner_root} is not writable by $(id -un)"
    exit 1
fi
if ! [ -s "${runners_token_file}" ]; then
    for kind in shell slurm; do
        if [ "$(eval echo "\${runners_${kind}}")" = "true" ] && ! [ -s "${runner_root}/tokens/${kind}.token" ]; then
            echo "::error title=Error::The ${kind} runner is not registered in ${runner_root} yet: give a personal access token (scopes api and create_runner) to register it"
            exit 1
        fi
    done
fi

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/runner-tools.sh"

echo "::notice title=Info::Controller setup complete."
