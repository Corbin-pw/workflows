#!/bin/bash
# start-template.sh - host desktop through a pw endpoint (runs on the compute node)
#
# Serves the compute image's own KasmVNC desktop (system kasmvncserver +
# GNOME). Xvnc serves the web client and the websocket itself over HTTPS
# (the packaged vncserver wrapper uses the system TLS certificate, which the
# users group can read), so the endpoint client is `pw endpoints https` and
# no reverse proxy, noVNC download, or container is needed.
#
# From inputs.sh:
#   - endpoint_name / endpoint_slug: pw endpoints registration
#   - pw_endpoints_args: --no-subdomain (emed has no session subdomains) and
#     --strip-path (Xvnc serves at the root; the platform forwards the full
#     /me/session/<user>/<name>/ prefix, and the slug's host= parameter makes
#     the viewer open its websocket under that prefix)
#   - password: vestigial (web basic auth is disabled; the endpoint already
#     requires platform login), but the viewer accepts it in the URL
#   - service_desktop: -select-de value for the vncserver wrapper (gnome)
#   - service_load_env / service_bin (app variants): command that puts the app
#     on the PATH (module load ...) and the binary to run on the desktop

set -o pipefail
set -x

echo "::group::Desktop Service Starting (Compute Node)"

# Write cancel.sh first so a cancel at any moment finds it.
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
echo "mv cancel.sh cancel.sh.executed" >> cancel.sh

for _cmd in vncserver vncpasswd Xvnc; do
    if ! command -v ${_cmd} >/dev/null 2>&1; then
        echo "::error title=Error::${_cmd} not found: this variant needs the emed compute image (kasmvncserver + GNOME). Was the job scheduled?"
        exit 1
    fi
done

# The emed login environment activates a conda base whose libraries corrupt
# the desktop session (github.com/parallelworks/issues/issues/1081).
if [ -n "${CONDA_PREFIX}" ]; then
    echo "::notice::Deactivating conda environment ${CONDA_PREFIX}"
    source ${CONDA_PREFIX}/etc/profile.d/conda.sh 2>/dev/null && conda deactivate
    export LD_LIBRARY_PATH=$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' | grep -v 'conda' | tr '\n' ':' | sed 's/:$//')
fi

# Pick a free display. The RFB port is 5900+display and the websocket port is
# derived as 25900+display: below the kernel's ephemeral range (32768+), so a
# port cannot be stolen between selection and Xvnc's bind, and node-unique
# because the display number is.
find_available_display() {
    local port displayNumber x11Port
    for port in $(seq 5901 5999 | shuf); do
        displayNumber=${port: -2}
        XdisplayNumber=${displayNumber#0}
        if netstat -aln | grep -qE "LISTEN.*:(${port}|$((6000 + XdisplayNumber))|$((25900 + XdisplayNumber)))\b" 2>/dev/null; then
            continue
        fi
        if [ -e "/tmp/.X11-unix/X${XdisplayNumber}" ] || [ -e "/tmp/.X${XdisplayNumber}-lock" ]; then
            continue
        fi
        if pgrep -f "(Xvnc|Xorg|Xvfb) :${XdisplayNumber}( |$)" > /dev/null 2>&1; then
            continue
        fi
        export DISPLAY=":${XdisplayNumber}"
        export displayPort=${port}
        export service_ws_port=$((25900 + XdisplayNumber))
        return 0
    done
    return 1
}

find_available_display || { echo "::error title=Error::No available display found"; exit 1; }

# Vestigial viewer credential: web basic auth is disabled below and the
# endpoint requires platform login, but the wrapper insists on a user entry.
printf "%s\n%s\n" "${password}" "${password}" | vncpasswd -u "${USER}" -w -r

echo "::notice::Starting KasmVNC desktop on display ${DISPLAY} (websocket port ${service_ws_port})"
vncserver ${DISPLAY} \
    -select-de "${service_desktop:-gnome}" \
    -disableBasicAuth \
    -interface 127.0.0.1 \
    -websocketPort ${service_ws_port} \
    -rfbport ${displayPort}
if [ $? -ne 0 ]; then
    echo "::error title=Error::vncserver failed to start on display ${DISPLAY}"
    exit 1
fi

# The wrapper daemonizes Xvnc and the desktop session, so they outlive this
# script's process tree: cancel.sh must tear them down explicitly.
echo "vncserver -kill ${DISPLAY}" >> cancel.sh
echo "pkill -KILL -f \"Xvnc ${DISPLAY}( |\$)\" 2>/dev/null" >> cancel.sh

# GNOME plus Xvnc need about a minute before the web port answers; register
# the endpoint only once it serves so it never points at a dead port.
echo "::notice::Waiting for the KasmVNC web server on port ${service_ws_port}"
web_up=""
for _i in $(seq 1 36); do
    if curl -sk -o /dev/null --max-time 5 "https://127.0.0.1:${service_ws_port}/vnc.html"; then
        web_up=1
        break
    fi
    if ! pgrep -f "Xvnc ${DISPLAY}( |$)" > /dev/null 2>&1; then
        break
    fi
    sleep 5
done
if [ -z "${web_up}" ]; then
    echo "::error title=Error::KasmVNC web server never answered on port ${service_ws_port}"
    echo "--- Xvnc log ---"
    cat ${HOME}/.vnc/$(hostname)${DISPLAY}.log 2>/dev/null | tail -40
    bash cancel.sh || true
    exit 1
fi

# App variants (emed_rstudio, emed_matlab, ...) pass a "command to load the
# app" plus a binary; both run natively on this node against the desktop's
# display. Composed so an empty load command doesn't leave a leading ";".
if [ -n "${service_bin}" ]; then
    startup_command="${service_load_env:+${service_load_env}; }${service_bin}"
    # X can accept connections slightly after the web server answers
    for _i in $(seq 1 12); do
        xset q >/dev/null 2>&1 && break
        sleep 5
    done
    echo "::notice::Running startup command: ${startup_command}"
    # stdin is a read-write FIFO, which never returns EOF: a console-driven GUI
    # app (vmd) otherwise sees EOF on the backgrounded job's stdin and exits
    # normally right after starting. A missing binary only logs an error in
    # run.out; the desktop itself keeps serving.
    mkfifo startup-stdin.fifo 2>/dev/null || true
    eval ${startup_command} 0<> startup-stdin.fifo &
    startup_command_pid=$!
    echo "kill ${startup_command_pid} || true # startup_command" >> cancel.sh
    echo "rm -f $PWD/startup-stdin.fifo" >> cancel.sh
fi

echo "::notice::Registering endpoint ${endpoint_name}"
pw endpoints https ${pw_endpoints_args} --name "${endpoint_name}" --slug "${endpoint_slug}" --output text ${service_ws_port} &
endpoint_pid=$!
echo "kill ${endpoint_pid} || true # pw endpoints https" >> cancel.sh

# Job lifetime = endpoint client AND Xvnc: whichever dies first ends the job,
# which is what makes `pw endpoints delete` (and a desktop crash) tear the
# whole thing down. Xvnc is a daemon, not a child, so poll instead of wait.
while kill -0 ${endpoint_pid} 2>/dev/null && pgrep -f "Xvnc ${DISPLAY}( |$)" > /dev/null 2>&1; do
    sleep 15
done
if kill -0 ${endpoint_pid} 2>/dev/null; then
    echo "::error title=Error::Desktop Xvnc ${DISPLAY} exited; tearing down"
else
    echo "::error title=Error::Endpoint client for ${endpoint_name} exited; tearing down"
fi
# Run the cleanup here instead of relying on the workflow's exit trap, so the
# desktop dies even if this template runs without the trap wrapper. Safe both
# ways: cancel.sh moves itself aside on its first line.
bash cancel.sh || true
echo "::endgroup::"
# Never cancel the run from here: a non-zero exit before the endpoint registered
# fails the run through the submitter job's error step, and once the run has
# completed nothing reads this status.
exit 1
