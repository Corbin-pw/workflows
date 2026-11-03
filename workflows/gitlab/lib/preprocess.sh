#!/bin/bash
################################################################################
# GitLab preprocessing, shared by every variant of the workflow
#
# Purpose: The two steps after Create Inputs, written once for every variant:
#          `controller` runs the controller of the mode (and, in gitlab mode,
#          of the container runtime) on the login node; `service-script`
#          assembles the script the submitter runs from inputs.sh, the
#          cleanup trap and the mode's start template, and publishes its
#          path, the SKIP_CLEANUP path, and the endpoint's name and health
#          path, which differ between the modes, through $OUTPUTS.
# Runs on: Controller node, from the job directory
# Called by: the preprocessing job's steps
#
# Required Environment Variables:
#   - mode: gitlab or runner
#   - container_runtime: gitlab-singularity or gitlab-docker (gitlab mode)
#   - service_name: the endpoint name prefix (gitlab mode)
#   - OUTPUTS, PW_JOB_ID, PW_RUN_SLUG: the platform's
################################################################################

set -o pipefail
set -x

lib=workflows/gitlab/lib
case "${mode}" in
    runner)
        controller="${lib}/runner-controller.sh"
        template="${lib}/runner-start-template.sh"
        endpoint_name="gitlab-runners-${PW_RUN_SLUG}"
        health_path=/
        ;;
    *)
        controller="workflows/gitlab/${container_runtime}/controller.sh"
        template="workflows/gitlab/${container_runtime}/start-template.sh"
        endpoint_name="${service_name:-gitlab}-${PW_RUN_SLUG}"
        health_path=/users/sign_in
        ;;
esac

case "$1" in
    controller)
        # This script prepares the target host and always runs in the controller node
        cp inputs.sh "controller-${PW_JOB_ID}.sh"
        cat "${controller}" >> "controller-${PW_JOB_ID}.sh"
        bash "controller-${PW_JOB_ID}.sh"
        ;;
    service-script)
        rm -f HOSTNAME SESSION_PORT job.ended job.started
        echo "export pw_endpoints_args=\"--name ${endpoint_name}\"" >> inputs.sh
        # This script starts the service
        cp inputs.sh "start-service-${PW_JOB_ID}.sh"
        # Write code common to all services
        cat <<'EOF' >> "start-service-${PW_JOB_ID}.sh"

cleanup() {
    trap - EXIT INT TERM HUP QUIT USR1 USR2 PIPE
    echo "::notice::Cleaning up..."
    if [ -f cancel.sh ]; then
        mv cancel.sh cancel.sh.submitted
        echo "echo Cleanup script was already executed" > cancel.sh
        bash cancel.sh.submitted
    fi
    kill -- -$$
}

trap cleanup EXIT INT TERM HUP QUIT USR1 USR2 PIPE

echo "::notice::Starting service"
EOF
        cat "${template}" >> "start-service-${PW_JOB_ID}.sh"
        {
            echo "ENDPOINT_NAME=${endpoint_name}"
            echo "HEALTH_PATH=${health_path}"
            echo "SCRIPT_PATH=${PWD}/start-service-${PW_JOB_ID}.sh"
            echo "SKIP_CLEANUP_PATH=${PWD}/SKIP_CLEANUP"
        } | tee -a "${OUTPUTS}"
        ;;
    *)
        echo "::error title=Error::preprocess.sh takes controller or service-script"
        exit 1
        ;;
esac
