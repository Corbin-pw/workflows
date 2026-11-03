################################################################################
# GitLab CI runner tools, shared by both modes of the workflow
#
# Purpose: Install gitlab-runner and, for the SLURM runner, Jacamar CI into
#          the install directory, each under <tool>/<version>/ with a
#          <tool>/current symlink the start scripts follow, and check what the
#          SLURM runner needs of the cluster.
# Runs on: Controller node
# Called by: lib/controller.sh (gitlab mode), lib/runner-controller.sh (runner mode)
#
# Required Environment Variables:
#   - service_parent_install_dir: where gitlab-runner and jacamar are installed
#   - runners_shell / runners_slurm: which CI runners to register
################################################################################

GITLAB_RUNNER_VERSION=v19.5.1
# From the release's release.sha256 (binaries/gitlab-runner-linux-amd64)
GITLAB_RUNNER_SHA256=0e11e71404352e67d286269aee397ec8e2825e0fc91a12f60c04cef0b85edb85
JACAMAR_VERSION=0.31.0
# The ubi9 build is a static binary; the checksum is the registry's
JACAMAR_TARBALL="jacamar-ci-${JACAMAR_VERSION}.ubi9.amd64.tar.gz"
JACAMAR_SHA256=708a368859f69ae53ae48dd70c54ac25ab586a6341b3db9521dd07ad720c7952

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null; then
    echo "::error title=Error::python3 3.6 or newer is needed on $(hostname) (found: $(python3 --version 2>&1 || echo none))"
    exit 1
fi

# The install directory may be shared by every user of the platform (the HSP
# project directory): a tool another user installed there is used as it is,
# readable and executable by everyone (the umask of a hardened node would
# make it the installer's alone), and a user who can write neither the tool
# nor the directory installs into their own software directory. The start
# scripts look in both places (runners_find_tool in lib/runners.sh)
tool_install_dir() {
    # tool_install_dir <tool> <version> <binary>: prints the base directory to install into
    local shared="${service_parent_install_dir}/$1"
    if [ -x "${shared}/$2/$3" ] && "${shared}/$2/$3" --version >/dev/null 2>&1; then
        echo "${service_parent_install_dir}"
    elif mkdir -p "${shared}" 2>/dev/null && [ -w "${shared}" ]; then
        echo "${service_parent_install_dir}"
    else
        echo "::warning::${shared} is not writable; installing $1 into ${HOME}/pw/software instead" >&2
        echo "${HOME}/pw/software"
    fi
}
tool_publish() {
    # tool_publish <base> <tool> <version>: a current symlink, and the install readable by everyone
    chmod a+rX "$1/$2" "$1/$2/$3" "$1/$2/$3"/* 2>/dev/null || true
    if [ -w "$1/$2" ]; then
        ln -sfn "$3" "$1/$2/current"
    fi
}

if [ "${runners_shell}" = "true" ] || [ "${runners_slurm}" = "true" ]; then
    runner_base=$(tool_install_dir gitlab-runner "${GITLAB_RUNNER_VERSION}" gitlab-runner)
    runner_dir="${runner_base}/gitlab-runner/${GITLAB_RUNNER_VERSION}"
    runner_bin="${runner_dir}/gitlab-runner"
    if ! [ -x "${runner_bin}" ] || ! "${runner_bin}" --version >/dev/null 2>&1; then
        echo "Installing gitlab-runner ${GITLAB_RUNNER_VERSION} into ${runner_dir}"
        mkdir -p "${runner_dir}"
        if ! curl -sSL --retry 3 -o "${runner_bin}.tmp" \
            "https://gitlab-runner-downloads.s3.amazonaws.com/${GITLAB_RUNNER_VERSION}/binaries/gitlab-runner-linux-amd64"; then
            echo "::error title=Error::Could not download gitlab-runner ${GITLAB_RUNNER_VERSION}"
            exit 1
        fi
        if ! echo "${GITLAB_RUNNER_SHA256}  ${runner_bin}.tmp" | sha256sum -c --quiet; then
            echo "::error title=Error::gitlab-runner ${GITLAB_RUNNER_VERSION} does not match its checksum"
            rm -f "${runner_bin}.tmp"
            exit 1
        fi
        chmod +x "${runner_bin}.tmp"
        mv "${runner_bin}.tmp" "${runner_bin}"
    fi
    "${runner_bin}" --version | head -n 1
    tool_publish "${runner_base}" gitlab-runner "${GITLAB_RUNNER_VERSION}"
fi

if [ "${runners_slurm}" = "true" ]; then
    for tool in sbatch squeue scancel sacct; do
        if ! command -v ${tool} >/dev/null 2>&1; then
            echo "::error title=Error::The SLURM runner needs ${tool} on $(hostname); it is not on the PATH"
            exit 1
        fi
    done
    # Jacamar reads a job's final state from sacct, which answers only with
    # accounting storage configured
    accounting=$(scontrol show config 2>/dev/null | awk -F'= *' '/^AccountingStorageType/ { print $2 }')
    case "${accounting}" in
        ""|"(null)"|*none*)
            echo "::error title=Error::The SLURM runner needs SLURM accounting (sacct), which this cluster has off (AccountingStorageType=${accounting:-unset}): Jacamar CI reads every job's final state from it. Launch without the SLURM runner"
            exit 1
            ;;
    esac
    jacamar_base=$(tool_install_dir jacamar-ci "${JACAMAR_VERSION}" jacamar)
    jacamar_dir="${jacamar_base}/jacamar-ci/${JACAMAR_VERSION}"
    jacamar_bin="${jacamar_dir}/jacamar"
    if ! [ -x "${jacamar_bin}" ] || ! "${jacamar_bin}" --version >/dev/null 2>&1; then
        echo "Installing Jacamar CI ${JACAMAR_VERSION} into ${jacamar_dir}"
        mkdir -p "${jacamar_dir}"
        if ! curl -sSL --retry 3 -o "${jacamar_dir}/${JACAMAR_TARBALL}" \
            "https://gitlab.com/api/v4/projects/ecp-ci%2Fjacamar-ci/packages/generic/jacamar-ci/${JACAMAR_VERSION}/${JACAMAR_TARBALL}"; then
            echo "::error title=Error::Could not download Jacamar CI ${JACAMAR_VERSION}"
            exit 1
        fi
        if ! echo "${JACAMAR_SHA256}  ${jacamar_dir}/${JACAMAR_TARBALL}" | sha256sum -c --quiet; then
            echo "::error title=Error::${JACAMAR_TARBALL} does not match its checksum"
            rm -f "${jacamar_dir}/${JACAMAR_TARBALL}"
            exit 1
        fi
        tar -xzf "${jacamar_dir}/${JACAMAR_TARBALL}" -C "${jacamar_dir}" jacamar
        rm -f "${jacamar_dir}/${JACAMAR_TARBALL}"
        chmod +x "${jacamar_bin}"
    fi
    "${jacamar_bin}" --version | head -n 1
    tool_publish "${jacamar_base}" jacamar-ci "${JACAMAR_VERSION}"
fi
