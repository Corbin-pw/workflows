################################################################################
# GitLab controller, shared by gitlab-docker and gitlab-singularity (gitlab mode)
#
# Purpose: Check the form's values and install the CI runner tools
#          (lib/runner-tools.sh) on the login node. Each runtime's
#          controller.sh sources this file and adds what its runtime needs
#          (the Singularity one pulls the SIF; the Docker image is pulled in
#          start-template.sh on the node where the job runs, because image
#          caches are not shared between nodes).
# Runs on: Controller node
# Called by: workflows/gitlab/<runtime>/controller.sh (workflow preprocessing step)
#
# Required Environment Variables:
#   - service_rundir: holds config/, data/, logs/ and runner/
#   - service_parent_install_dir: where gitlab-runner and jacamar are installed
#   - service_root_password_file: optional; the root password the form carries
#   - runners_shell / runners_slurm: which CI runners to register
#   - runners_group: optional; the path of the group that owns the runners
#   - oidc_client_id / oidc_client_secret_file: both set, or neither
################################################################################

if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/gitlab
fi
rundir=$(realpath -m "${service_rundir}")

mkdir -p "${rundir}"
if ! [ -w "${rundir}" ]; then
    echo "::error title=Error::The run directory ${rundir} is not writable by $(id -un)"
    exit 1
fi

if [ -s "${service_root_password_file}" ]; then
    if [ "$(wc -c < "${service_root_password_file}")" -lt 9 ]; then
        echo "::error title=Error::GitLab needs a root password of at least 8 characters"
        exit 1
    fi
fi

if [ -n "${oidc_client_id}" ] && ! [ -s "${oidc_client_secret_file}" ]; then
    echo "::error title=Error::Sign in with ACTIVATE needs the client secret of application ${oidc_client_id}"
    exit 1
fi
if [ -z "${oidc_client_id}" ] && [ -s "${oidc_client_secret_file}" ]; then
    echo "::error title=Error::Sign in with ACTIVATE needs the client ID that goes with the client secret"
    exit 1
fi

# A GitLab group path: letters, digits, underscores, dots and dashes, starting
# with a letter or digit, no slash (a top-level group)
if [ -n "${runners_group}" ] && ! printf '%s' "${runners_group}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
    echo "::error title=Error::The group of the runners must be a top-level group path (letters, digits, dashes, underscores and dots): ${runners_group}"
    exit 1
fi

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/runner-tools.sh"
