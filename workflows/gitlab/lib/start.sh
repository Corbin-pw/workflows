################################################################################
# GitLab start template, shared by gitlab-docker and gitlab-singularity
#
# Purpose: What every runtime's start script does before its container starts:
#          defaults, the runner tools, the first half of cancel.sh (the CI
#          runner, lib/runners.sh), the pinned subdomain, the root password,
#          the exports the launcher reads, and finish_endpoint_run for the
#          status that pw endpoints run returns
# Runs on: Controller node
# Called by: workflows/gitlab/<runtime>/start-template.sh (sourced)
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_rundir: holds config/, data/, logs/, runner/ and the generated secrets
#   - service_subdomain: subdomain label of the URL (default gitlab-<PW_USER>)
#   - service_ssh_port: loopback port of GitLab's SSH
#   - service_root_password_file: optional; the root password for a first start
#   - runners_shell, runners_slurm: which CI runners to start
#   - runners_group: optional; the path of the group that owns the runners
#   - service_parent_install_dir: holds gitlab-runner/current and
#     jacamar-ci/current, installed by controller.sh when needed
#   - oidc_client_id, oidc_display_name: optional ACTIVATE OIDC client
################################################################################

if [ -z "${service_rundir}" ]; then
    service_rundir=${HOME}/gitlab
fi
service_rundir=$(realpath -m "${service_rundir}")
if [ -z "${service_ssh_port}" ]; then
    service_ssh_port=2222
fi
if [ -z "${oidc_display_name}" ]; then
    oidc_display_name=ACTIVATE
fi
if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
gitlab_lib="${PW_PARENT_JOB_DIR}/workflows/gitlab/lib"
source "${gitlab_lib}/runners.sh"
runner_root="${service_rundir}/runner"
gitlab_runner_bin=$(runners_find_tool gitlab-runner gitlab-runner)
jacamar_bin=$(runners_find_tool jacamar-ci jacamar)
if [ "${runners_shell}" = "true" ] || [ "${runners_slurm}" = "true" ]; then
    if ! [ -x "${gitlab_runner_bin}" ]; then
        echo "::error title=Error::gitlab-runner is not installed at ${gitlab_runner_bin} (the controller installs it)"
        exit 1
    fi
fi
if [ "${runners_slurm}" = "true" ] && ! [ -x "${jacamar_bin}" ]; then
    echo "::error title=Error::Jacamar CI is not installed at ${jacamar_bin} (the controller installs it)"
    exit 1
fi
mkdir -p "${service_rundir}/config" "${service_rundir}/data" "${service_rundir}/logs" "${runner_root}"
# Repositories, database, secrets and the runners' checkouts are the user's
# alone, whatever the umask of the login node
chmod 700 "${service_rundir}"

for tool in openssl curl flock python3; do
    if ! command -v ${tool} >/dev/null 2>&1; then
        echo "::error title=Error::${tool} is not installed on $(hostname)"
        exit 1
    fi
done

# Files of this job, not of the shared run directory: the nginx snippet, the
# container's environment, the launcher's exit status, the runner's session
export run_dir="${PWD}/run"
mkdir -p "${run_dir}"

# Neither the container nor the runner (started in a session of its own) is in
# the endpoint's process tree, so teardown needs cancel.sh (run by the cleanup
# trap) to stop them: the runner here, the container appended by the runtime
runners_write_cancel_sh
echo "rm -f \"${run_dir}/gitlab.env\"" >> cancel.sh

# GitLab builds its clone URLs and the OIDC redirect URI from its address, so
# the subdomain is pinned instead of taking a random one
if printf '%s' "${pw_endpoints_args}" | grep -q -- '--no-subdomain'; then
    echo "::error title=Error::GitLab serves at the root of its address and needs a subdomain endpoint; this platform has no session subdomains"
    exit 1
fi
if [ -z "${service_subdomain}" ] || [ "${service_subdomain}" = "undefined" ]; then
    service_subdomain="gitlab-${PW_USER}"
fi
service_subdomain=$(printf '%s' "${service_subdomain}" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g' | cut -c1-63 | sed 's/^-//; s/-$//')
in_use=$(pw endpoints list 2>/dev/null | awk -v host="https://${service_subdomain}." \
    '{ for (i = 2; i <= NF; i++) if (index($i, host) == 1) { print $1, $2; break } }' | head -n 1)
if [ -n "${in_use}" ]; then
    echo "::error title=Error::https://${service_subdomain}.* is already served by endpoint ${in_use%% *} (status: ${in_use#* }). Open that session, delete it with 'pw endpoints delete ${in_use%% *}', or run again with another subdomain"
    exit 1
fi
pw_endpoints_args="${pw_endpoints_args} --subdomain ${service_subdomain}"

# The root password only applies when the database is created, on the first
# start of a run directory; it is kept beside the data so a later run can
# tell the user where it is
root_password_file="${service_rundir}/.root_password"
has_database() {
    [ -d "${service_rundir}/data/postgresql/data" ]
}
if [ -s "${service_root_password_file}" ]; then
    if has_database; then
        echo "::warning::${service_rundir} already holds a database: the root password of the form is ignored; change it in GitLab (root's profile -> Password)"
    else
        (
            umask 077
            tr -d '\n' < "${service_root_password_file}" > "${root_password_file}"
        )
    fi
elif [ ! -s "${root_password_file}" ] && ! has_database; then
    (
        umask 077
        openssl rand -base64 18 | tr -d '/+=' | cut -c1-20 > "${root_password_file}"
    )
    echo "::notice::Generated the root password into ${root_password_file}"
fi

platform_host=${PW_PLATFORM_HOST#https://}
platform_host=${platform_host#http://}
platform_host=${platform_host%%/*}
if [ -n "${oidc_client_id}" ] && [ -z "${platform_host}" ]; then
    echo "::error title=Error::PW_PLATFORM_HOST is empty; the OIDC issuer URL cannot be built"
    exit 1
fi

# A host in FIPS mode (fips=1 on its kernel command line: STIG images) shows
# /proc/sys/crypto/fips_enabled = 1 to the container, whose OpenSSH then wants
# a FIPS provider the image does not have and dies while the entrypoint
# creates the SSH host keys ("PRNG is not seeded"). The image is not a FIPS
# build (GitLab ships those separately), so each runtime mounts this file,
# holding a 0, over that path when it is set
fips_enabled_file=""
if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = "1" ]; then
    echo 0 > "${run_dir}/fips_enabled"
    fips_enabled_file="${run_dir}/fips_enabled"
    echo "::notice::$(hostname) runs in FIPS mode; the container reads fips_enabled=0 (the GitLab image is not a FIPS build)"
fi

export gitlab_lib service_rundir service_subdomain service_ssh_port platform_host oidc_display_name root_password_file runner_root gitlab_runner_bin jacamar_bin fips_enabled_file runners_group

finish_endpoint_run() {
    # finish_endpoint_run <status of pw endpoints run>
    if [ "$1" -eq 0 ]; then
        echo "::endgroup::"
        return 0
    fi
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. A
    # launch that never registered its endpoint, or a launcher that gave up
    # after registering it, is a real failure.
    if [ -s "${run_dir}/launcher.exit" ]; then
        echo "::error title=Error::The GitLab launcher failed with status $(cat "${run_dir}/launcher.exit") (its messages are above)"
        exit 1
    fi
    local served_name
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    if [ -n "${service_subdomain}" ]; then
        echo "::error title=Error::If this is a subdomain conflict, another endpoint (possibly another user's) holds https://${service_subdomain}.*; run again with a different subdomain"
    fi
    exit 1
}
