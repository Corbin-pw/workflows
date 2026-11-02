#!/usr/bin/env bash
# Builds the GitLab Singularity SIF from gitlab.def (the official
# gitlab/gitlab-ee image plus rootless/, which makes it run as one
# unprivileged user) for upload to ghcr.io/parallelworks/gitlab:<tag> via
# ORAS, the file named after the tag because the controller pulls it by that
# name (GITLAB_SIF_TAG in controller.sh).
#
# Usage: ./build-container.sh
#
# Prerequisites: apptainer (or singularity) with --fakeroot (the %post step
# edits the image as root), oras; about 5 GB of scratch and 2 GB for the image
#
# After running, push the resulting SIF (the package must be public):
#   oras push ghcr.io/parallelworks/gitlab:<tag> gitlab-<tag>.sif

set -euo pipefail

cd "$(dirname "$0")"
TAG=$(sed -n 's/^GITLAB_SIF_TAG=//p' controller.sh)
SIF_NAME="gitlab-${TAG}.sif"

export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
export APPTAINER_TMPDIR=${SINGULARITY_TMPDIR} APPTAINER_CACHEDIR=${SINGULARITY_CACHEDIR}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"
if ! command -v singularity >/dev/null 2>&1 && command -v apptainer >/dev/null 2>&1; then
    singularity() { apptainer "$@"; }
fi

echo "Building ${SIF_NAME} from gitlab.def"
singularity build --force --fakeroot "${SIF_NAME}" gitlab.def

singularity exec "${SIF_NAME}" sh -c 'grep RELEASE_VERSION /RELEASE; test -x /assets/init-rootless && test -x /opt/gitlab/embedded/bin/chpst.real && test -L /opt/gitlab/sv && grep -q single-user /opt/gitlab/bin/gitlab-ctl && echo "single-user entrypoint, chpst wrapper and redirects present"'

echo ""
echo "Build complete: ${SIF_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/gitlab:${TAG} ${SIF_NAME}"
