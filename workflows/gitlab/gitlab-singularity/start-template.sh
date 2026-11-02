################################################################################
# Interactive Session Service Starter - GitLab (Singularity)
#
# Purpose: Run the single-user GitLab image as the workflow user: an
#          Apptainer/Singularity instance with no root, no fakeroot and no
#          writable layer. Every service of the Linux package runs as the
#          user, whom the container's passwd names git (and every other
#          account of the package), so the image needs no subuid range and
#          nothing it writes belongs to another id: the run directory can be
#          on any filesystem (NFS, Lustre, GPFS) and is removed with rm -rf.
#          The SIF runs as is where the node mounts it; a node that cannot
#          mount a SIF for an unprivileged user (no FUSE: hardened login
#          nodes) runs the image extracted once into the install directory.
#          Behind a pw endpoint on a pinned subdomain, with ACTIVATE as an
#          OpenID Connect provider when the form carries an OIDC client, a
#          license, the CI runners (shell on this host, SLURM through Jacamar
#          CI). What does not depend on the runtime is in lib/start.sh (this
#          script) and lib/launcher.sh (the launcher).
# Runs on: Controller node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_parent_install_dir: where containers/gitlab.sif lives
#   - the variables lib/start.sh and lib/launcher.sh list
################################################################################

set -x
set -o pipefail

source "${PW_PARENT_JOB_DIR}/workflows/gitlab/lib/start.sh"

container_sif="${service_parent_install_dir}/containers/gitlab.sif"
work_dir="${service_rundir}/work"
# work/ holds the container's /tmp and /var/tmp (--workdir), a real temporary
# directory (world-writable and sticky: Ruby's Dir.tmpdir accepts nothing
# less), and the temporary files of singularity itself, which the host's /tmp
# may refuse (noexec); the config/activate mount point must exist before the
# config volume is bound over it
mkdir -p "${work_dir}/tmp" "${service_rundir}/config/activate" "${HOME}/.singularity_cache"
chmod 1777 "${work_dir}/tmp"
export APPTAINER_TMPDIR="${work_dir}/tmp" SINGULARITY_TMPDIR="${work_dir}/tmp"
export APPTAINER_CACHEDIR="${HOME}/.singularity_cache" SINGULARITY_CACHEDIR="${HOME}/.singularity_cache"

# The runtime: apptainer first (it mounts SIFs without setuid and bundles
# squashfuse), singularity otherwise, each from the PATH or its environment
# module, and only one whose engine answers: a module can ship a build that
# panics on this node (the kasmvnc workflow met one), so the version call is
# the first thing asked of it
container_cmd=""
for rt in apptainer singularity; do
    command -v ${rt} >/dev/null 2>&1 || module load ${rt} >/dev/null 2>&1 || true
    if command -v ${rt} >/dev/null 2>&1 && ${rt} --version >/dev/null 2>&1; then
        container_cmd=${rt}
        break
    fi
done
if [ -z "${container_cmd}" ]; then
    echo "::error title=Error::Neither apptainer nor singularity runs on $(hostname) (PATH or environment modules)"
    exit 1
fi
echo "::notice::Container runtime: ${container_cmd} ($(${container_cmd} --version 2>/dev/null))"
export container_cmd
if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif}"
    exit 1
fi

# Host environments (module paths, LD_LIBRARY_PATH on HPC) must not leak into
# the container; the image's own environment is all it needs
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# The image is read-only at run time (what the package writes goes to the run
# directory through symlinks baked into the image), so it runs as is where
# this node mounts a SIF for an unprivileged user, and otherwise from a
# directory it is extracted into once, under the user's own software
# directory (a shared install directory would leave the first user's
# extraction in the way of the next one's), shared by every run directory of
# the user since nothing writes to it; a marker names the SIF it came from,
# so a new image replaces it. The probe runs here, on the node that runs the
# service
sif_file=$(readlink -f "${container_sif}")
sif_id="$(basename "${sif_file}") $(stat -c %s "${sif_file}")"
if "${container_cmd}" exec "${container_sif}" /bin/true >/dev/null 2>&1; then
    image_ref="${container_sif}"
    echo "::notice::Running ${container_sif} as is (this node mounts it)"
else
    image_dir="${HOME}/pw/software/containers/$(basename "${sif_file%.sif}")-sandbox"
    image_marker="${image_dir}.source"
    mkdir -p "$(dirname "${image_dir}")"
    if [ -d "${image_dir}" ] && [ "$(cat "${image_marker}" 2>/dev/null)" != "${sif_id}" ]; then
        echo "::notice::Removing ${image_dir}, extracted from $(cat "${image_marker}" 2>/dev/null || echo 'an unknown or interrupted image'); ${sif_id%% *} replaces it"
        rm -rf "${image_dir}" "${image_marker}"
    fi
    if ! [ -d "${image_dir}" ]; then
        echo "::notice::$(hostname) cannot mount ${container_sif} for an unprivileged user (no FUSE for a user namespace); extracting it into ${image_dir} (a few minutes, once per user)"
        if ! "${container_cmd}" build --force --sandbox "${image_dir}" "${container_sif}"; then
            rm -rf "${image_dir}"
            echo "::error title=Error::Could not extract ${container_sif} on $(hostname) (above)"
            exit 1
        fi
        echo "${sif_id}" > "${image_marker}"
    fi
    image_ref="${image_dir}"
    echo "::notice::Running the image extracted into ${image_dir}"
fi
if ! "${container_cmd}" exec --contain "${image_ref}" test -x /assets/init-rootless; then
    echo "::error title=Error::${image_ref} is not the single-user GitLab image (no /assets/init-rootless): remove ${container_sif} so the controller pulls the image its GITLAB_SIF_TAG names"
    exit 1
fi

# The container's /etc/passwd and /etc/group: this user's id under the name
# git (first, so that is the account's name) and under every other account of
# the package, from the templates the image carries, so the package's
# ownership checks and PostgreSQL's peer authentication see the accounts they
# expect while every process is the user's
for f in passwd group; do
    if ! "${container_cmd}" exec --contain "${image_ref}" cat "/assets/rootless/${f}.in" \
            | sed "s/@UID@/$(id -u)/g; s/@GID@/$(id -g)/g" > "${run_dir}/${f}" || ! [ -s "${run_dir}/${f}" ]; then
        echo "::error title=Error::Could not read /assets/rootless/${f}.in from ${image_ref}"
        exit 1
    fi
done

export image_ref work_dir
export instance_name="gitlab_${PW_RUN_SLUG}"

# The instance outlives the endpoint's process tree: cancel.sh stops the
# package's services (a TERM to the entrypoint's host-side process does not
# reach the script inside), then the instance, whose PID namespace takes the
# rest with it. The submitter runs it over ssh, in a shell that has not loaded
# the module this script may have
cat >> cancel.sh <<CANCELEOF
command -v ${container_cmd} >/dev/null 2>&1 || module load ${container_cmd} 2>/dev/null
if ${container_cmd} instance list 2>/dev/null | awk '{ print \$1 }' | grep -qxF "${instance_name}"; then
    timeout 30 ${container_cmd} exec --cleanenv --pwd / instance://${instance_name} gitlab-ctl stop 2>/dev/null
    ${container_cmd} instance stop -F ${instance_name} 2>/dev/null || true
fi
CANCELEOF

echo "::group::Starting GitLab"

# pw endpoints run exports PORT, PW_ENDPOINT_HOST, PW_ENDPOINT_PATH and
# PW_ENDPOINT_URL to the wrapped command; the launcher writes the container's
# configuration at runtime because GitLab must know its public host name
# (external_url: absolute URLs, clone URLs, the OIDC redirect URI) before it
# starts. The image's entrypoint, run in the instance's foreground, keeps the
# endpoint alive for the life of the container.
cat > launch-gitlab-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
set -o pipefail

source "${gitlab_lib}/launcher.sh"
gitlab_launcher_init
gitlab_write_nginx_snippet
# The container shares the host's network, so the bundled nginx listens on the
# endpoint's own port and GitLab's SSH server (gitlab-sshd, which runs as the
# user) on the form's, and every other TCP listener of the package (fixed
# loopback ports in the image, which Docker isolates per container) is moved
# to a free port or turned off, so that two GitLabs on one host do not
# collide: puma's port (workhorse reaches it over its unix socket), the
# metrics of workhorse, gitaly and gitlab-sshd, sidekiq's metrics and health
# checks, nginx's status page (on every interface) and the Kubernetes agent
# server
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}
gitlab_write_omnibus_config "${PORT}" \
    "nginx['listen_addresses'] = ['127.0.0.1']" \
    "nginx['status']['enable'] = false" \
    "puma['port'] = $(free_port)" \
    "gitlab_workhorse['prometheus_listen_addr'] = '127.0.0.1:$(free_port)'" \
    "gitaly['configuration'] = { prometheus_listen_addr: '127.0.0.1:$(free_port)' }" \
    "sidekiq['metrics_enabled'] = false" \
    "sidekiq['health_checks_enabled'] = false" \
    "gitlab_kas['enable'] = false" \
    "gitlab_sshd['listen_address'] = '127.0.0.1:${service_ssh_port}'" \
    "gitlab_sshd['metrics_address'] = '127.0.0.1:$(free_port)'"

# The configuration goes in as a host variable with the APPTAINERENV_ /
# SINGULARITYENV_ prefix: it reaches the container with --cleanenv and stays
# out of the process list. Apptainer expands $, backticks and backslashes in
# such values, so they are escaped and arrive verbatim. The package's logs
# stay in logs/ instead of being tailed into this job's output forever
set +x
config=$(sed 's/^GITLAB_OMNIBUS_CONFIG=//' "${run_dir}/gitlab.env" | sed 's/[\\$`]/\\&/g')
export APPTAINERENV_GITLAB_OMNIBUS_CONFIG="${config}" SINGULARITYENV_GITLAB_OMNIBUS_CONFIG="${config}"
unset config
set -x
export APPTAINERENV_GITLAB_SKIP_TAIL_LOGS=true SINGULARITYENV_GITLAB_SKIP_TAIL_LOGS=true

gitlab_exec() {
    "${container_cmd}" exec --cleanenv --pwd / instance://"${instance_name}" "$@"
}
gitlab_alive() {
    kill -0 "$(cat "${run_dir}/wrapper.pid")" 2>/dev/null
}
gitlab_logs() {
    tail -n 80 "${run_dir}/gitlab.log"
}

# The 0 a FIPS-mode host hands the container (lib/start.sh); binds over proc
# files are allowed
fips_bind=""
if [ -n "${fips_enabled_file}" ]; then
    fips_bind="--bind ${fips_enabled_file}:/proc/sys/crypto/fips_enabled"
fi

# The image's volumes are bound from the run directory (every mount point
# exists in the image), the accounts and the snippet directory from this job
"${container_cmd}" instance stop -F "${instance_name}" 2>/dev/null || true
if ! "${container_cmd}" instance start --contain --cleanenv \
        --uts --hostname "${host}" \
        --workdir "${work_dir}" ${fips_bind} \
        --bind "${service_rundir}/config:/etc/gitlab" \
        --bind "${service_rundir}/data:/var/opt/gitlab" \
        --bind "${service_rundir}/logs:/var/log/gitlab" \
        --bind "${run_dir}/passwd:/etc/passwd" \
        --bind "${run_dir}/group:/etc/group" \
        --bind "${run_dir}/activate:/etc/gitlab/activate:ro" \
        "${image_ref}" "${instance_name}"; then
    fail "Could not start the GitLab instance ${instance_name} (above)"
fi
"${container_cmd}" exec --cleanenv --pwd / instance://"${instance_name}" /assets/init-rootless > "${run_dir}/gitlab.log" 2>&1 &
echo $! > "${run_dir}/wrapper.pid"

gitlab_wait_ready
gitlab_setup

wait "$(cat "${run_dir}/wrapper.pid")"
gitlab_logs
fail "The GitLab container stopped (its log is above; the package's logs are in ${service_rundir}/logs)"
LAUNCHEOF
chmod +x launch-gitlab-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-gitlab-${PW_JOB_ID}.sh
finish_endpoint_run $?
