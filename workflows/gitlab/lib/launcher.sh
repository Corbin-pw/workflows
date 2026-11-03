################################################################################
# GitLab launcher library, shared by gitlab-docker and gitlab-singularity
#
# Purpose: Everything the script that pw endpoints run executes does that does
#          not depend on the container runtime: the public host and the lock,
#          the nginx snippet (forwarded headers, the OIDC hop page and the
#          readiness gate, the route that tells other users' runners where
#          this GitLab listens), the Linux package's configuration, the wait
#          for the sign-in page, and the setup after the boot (license, the
#          owner's group and account, the CI runners through lib/runners.sh).
#          The launcher sources it, defines gitlab_exec (run a command in the
#          container), gitlab_alive (is the container running) and gitlab_logs
#          (print the tail of its log) for its runtime, starts the container
#          and calls gitlab_wait_ready, then gitlab_setup.
# Runs on: Controller node, under pw endpoints run (PORT,
#          PW_ENDPOINT_HOST, PW_ENDPOINT_PATH, PW_ENDPOINT_URL exported)
#
# Required Environment Variables (exported by lib/start.sh):
#   - run_dir: this job's run/ directory (activate/, gitlab.env, launcher.exit)
#   - service_rundir, service_ssh_port, root_password_file, service_license_file
#   - runners_shell, runners_slurm, runners_group, runner_root,
#     gitlab_runner_bin, jacamar_bin
#   - platform_host, oidc_client_id, oidc_client_secret_file, oidc_display_name,
#     oidc_block_new_users
################################################################################

source "${gitlab_lib}/runners.sh"

# A failure here ends pw endpoints run with the endpoint already registered,
# which the start script cannot tell from the cancel that releases a healthy
# run: the exit file says which it was
fail() {
    echo "::error title=Error::$1"
    echo "${2:-1}" > "${run_dir}/launcher.exit"
    exit "${2:-1}"
}

gitlab_launcher_init() {
    rm -f "${run_dir}/launcher.exit"
    host="${PW_ENDPOINT_HOST}"
    if [ -z "${host}" ]; then
        host=$(printf '%s' "${PW_ENDPOINT_URL}" | sed -E 's#^https?://##; s#[/?].*$##')
    fi
    if [ -z "${host}" ]; then
        fail "pw endpoints run did not export the endpoint host (PW_ENDPOINT_HOST / PW_ENDPOINT_URL)"
    fi
    if [ -n "${PW_ENDPOINT_PATH%/}" ]; then
        fail "GitLab serves at the root of its address; the endpoint path ${PW_ENDPOINT_PATH} is not supported"
    fi
    public_url="https://${host}/"
    api="http://127.0.0.1:${PORT}/api/v4"

    # Two servers on one data directory would both start and corrupt it; the
    # lock is held on fd 9 for the life of the launcher, which therefore waits
    # for its foreground command instead of exec'ing into it (sudo closes
    # inherited fds). A run started right after the previous one's session
    # was deleted finds the old launcher still letting go, so the lock is
    # waited for a minute
    exec 9>"${service_rundir}/.lock"
    if ! flock -w 60 9; then
        fail "${service_rundir} is in use by another GitLab run; choose another run directory or stop that one first" 75
    fi
}

# The platform proxy forwards X-Forwarded-Proto: http, under which GitLab (an
# https external_url) redirects every page to itself and refuses to write its
# Secure session cookie, so the bundled nginx sets the forwarded headers
# itself. The same proxy also rewrites every redirect to another host onto
# the session's own host, which would send the browser to <this host>/api/
# oidc/authorize instead of the platform's sign-in: for the one route that
# redirects to the identity provider, nginx intercepts the 3xx and answers a
# 200 page that navigates there itself (redirects within this host are
# re-issued as they were). The directory is mounted into the config volume
# and its file included from the server block, so the host's user can rewrite
# it on every start although the volume belongs to the container.
#
# The run completes as soon as the platform's probe of /users/sign_in gets a
# 200, while the runners are registered after GitLab answers: until this
# launcher touches the ready marker that page answers 503 to everyone but
# this launcher's own probe, so a setup failure fails the run instead of
# leaving a completed run whose service the cleanup then removed.
#
# A user who adds their own runners to this GitLab (the workflow's runner
# mode) must reach it on this host's loopback, so the snippet also answers,
# behind the platform's sign-in, which port it listens on, as which uid and
# on which host: the one piece of information the proxy's routing of the
# public address vouches for
gitlab_write_nginx_snippet() {
    local host_re
    host_re=$(printf '%s' "${host}" | sed 's/[.]/\\./g')
    # nginx's workers (an unprivileged user in the container) test the marker,
    # so the directory stays readable whatever the umask here
    mkdir -p "${run_dir}/activate"
    chmod 755 "${run_dir}/activate"
    rm -f "${run_dir}/activate/ready"
    cat > "${run_dir}/activate/nginx.conf" <<NGINXEOF
location = /users/sign_in {
    set \$activate_gate 0;
    if (!-f /etc/gitlab/activate/ready) { set \$activate_gate 1; }
    if (\$http_x_activate_probe) { set \$activate_gate 0; }
    if (\$activate_gate = 1) { return 503; }
    proxy_pass http://gitlab-workhorse;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host_with_default;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Ssl on;
}
location = /-/activate/host {
    default_type application/json;
    add_header Cache-Control no-store;
    return 200 '{"port": ${PORT}, "uid": $(id -u), "host": "$(hostname)"}';
}
location = /users/auth/openid_connect {
    proxy_pass http://gitlab-workhorse;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host_with_default;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Ssl on;
    proxy_intercept_errors on;
    error_page 301 302 303 307 308 = @activate_hop;
}
location @activate_hop {
    add_header Set-Cookie \$upstream_http_set_cookie;
    add_header Cache-Control no-store;
    if (\$upstream_http_location ~* "^https?://${host_re}(/|\$|[?#])") { return 302 \$upstream_http_location; }
    default_type text/html;
    return 200 '<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=\$upstream_http_location"><title>Redirecting</title></head><body><p>Continue to <a href="\$upstream_http_location">sign in</a>.</p></body></html>';
}
NGINXEOF
    chmod 644 "${run_dir}/activate/nginx.conf"
}

# gitlab_write_omnibus_config <nginx listen port> [more Ruby statements...]
# writes run/gitlab.env: GITLAB_OMNIBUS_CONFIG=<one Ruby line>, in the format
# of a docker --env-file. One line because that file takes no newlines; the
# Linux package evaluates it after gitlab.rb on every start. Secrets are read
# from their files here, so they stay out of the set -x trace
gitlab_write_omnibus_config() {
    local listen_port=$1
    shift
    set +x
    ruby_quote() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }
    local config=(
        "external_url 'https://${host}'"
        "nginx['listen_port'] = ${listen_port}"
        "nginx['listen_https'] = false"
        "nginx['proxy_set_headers'] = { 'Host' => '\$http_host_with_default', 'X-Real-IP' => '\$remote_addr', 'X-Forwarded-For' => '\$proxy_add_x_forwarded_for', 'X-Forwarded-Proto' => 'https', 'X-Forwarded-Ssl' => 'on', 'Upgrade' => '\$http_upgrade', 'Connection' => '\$connection_upgrade' }"
        "nginx['custom_gitlab_server_config'] = 'include /etc/gitlab/activate/nginx.conf;'"
        "letsencrypt['enable'] = false"
        "prometheus_monitoring['enable'] = false"
        "puma['worker_processes'] = 2"
        "sidekiq['concurrency'] = 10"
        "gitlab_rails['gitlab_shell_ssh_port'] = ${service_ssh_port}"
        "$@"
    )
    if [ -s "${root_password_file}" ]; then
        config+=("gitlab_rails['initial_root_password'] = '$(ruby_quote "$(cat "${root_password_file}")")'")
    fi
    if [ -n "${oidc_client_id}" ]; then
        local issuer="https://${platform_host}/api/oidc" block_new_users=false
        if [ "${oidc_block_new_users}" = "true" ]; then
            block_new_users=true
        fi
        config+=(
            "gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']"
            "gitlab_rails['omniauth_block_auto_created_users'] = ${block_new_users}"
            "gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']"
            "gitlab_rails['omniauth_providers'] = [{ name: 'openid_connect', label: '$(ruby_quote "${oidc_display_name}")', args: { name: 'openid_connect', scope: ['openid', 'profile', 'email'], response_type: 'code', issuer: '${issuer}', discovery: false, uid_field: 'preferred_username', pkce: true, client_options: { identifier: '$(ruby_quote "${oidc_client_id}")', secret: '$(ruby_quote "$(cat "${oidc_client_secret_file}")")', redirect_uri: '${public_url}users/auth/openid_connect/callback', authorization_endpoint: '${issuer}/authorize', token_endpoint: '${issuer}/token', userinfo_endpoint: '${issuer}/userinfo', jwks_uri: 'https://${platform_host}/api/platform/keys', end_session_endpoint: '${issuer}/end_session' } } }]"
        )
    else
        config+=("gitlab_rails['omniauth_providers'] = []")
    fi
    (
        umask 077
        {
            printf 'GITLAB_OMNIBUS_CONFIG='
            local sep="" line
            for line in "${config[@]}"; do
                printf '%s%s' "${sep}" "${line}"
                sep="; "
            done
            printf '\n'
        } > "${run_dir}/gitlab.env"
    )
    set -x
}

# The first boot of a run directory runs the whole configuration (minutes);
# later boots only reconfigure and migrate. The endpoint is already listed
# (the host name had to be known before the container could start), so a boot
# that fails must end this launcher, with the container's log, before the wait
# job's budget (1800 s) ends the run with a message that has none. The sign-in page, probed without a forwarded protocol
# like the platform does, answers 200 only when the header fix is in place
# (302 to itself otherwise)
gitlab_wait_ready() {
    echo "Waiting for GitLab to answer on 127.0.0.1:${PORT}"
    local code="" i
    for i in $(seq 1 300); do
        if ! gitlab_alive; then
            gitlab_logs
            fail "The GitLab container exited during start-up (log above)"
        fi
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Host: ${host}" -H "X-Activate-Probe: 1" "http://127.0.0.1:${PORT}/users/sign_in")
        if [ "${code}" = "200" ]; then
            break
        fi
        if [ $((i % 12)) -eq 0 ]; then
            echo "GitLab is still starting ($((i * 5)) s, last status ${code:-none})"
        fi
        sleep 5
    done
    if [ "${code}" != "200" ]; then
        gitlab_logs
        fail "GitLab's sign-in page did not answer 200 within 25 minutes (last status: ${code:-none})"
    fi
    echo "::notice::GitLab is serving at ${public_url}"
}

# The group the runners belong to, owned by the launching user's GitLab
# account: only the pipelines of its projects run on this host as the
# launching user. The group is created on the first start; with Sign in with
# ACTIVATE configured, the owner's account is created ahead of their first
# sign-in with the identity that sign-in will carry (uid_field
# preferred_username, so extern_uid is the ACTIVATE username) and made the
# group's Owner, and an account a sign-in created already is made Owner on a
# later start. Sets runner_type and runner_scope_id for lib/runners.sh
gitlab_owner_group() {
    local group_path="${runners_group:-${PW_USER}-ci}" encoded owner_id="" email
    encoded=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${group_path}")
    runners_api_call GET "/groups/${encoded}"
    if [ "${api_status}" = "200" ]; then
        group_id=$(printf '%s' "${api_body}" | json_get id)
    else
        runners_api_call POST /groups \
            --data-urlencode "name=${group_path}" --data-urlencode "path=${group_path}" \
            --data "visibility=private" \
            --data-urlencode "description=Projects whose pipelines run on ${PW_USER}'s CI runners on $(hostname)"
        group_id=$(printf '%s' "${api_body}" | json_get id)
        if [ "${api_status}" != "201" ] || [ -z "${group_id}" ]; then
            fail "Could not create the group ${group_path} for the runners (HTTP ${api_status}): $(printf '%s' "${api_body}" | json_get message)"
        fi
        echo "::notice::Created the group ${group_path}: projects in it run their pipelines on this host's runners"
    fi
    if [ -n "${oidc_client_id}" ]; then
        first_user_id() {
            python3 -c 'import json, sys; l = json.load(sys.stdin); print(l[0]["id"] if l else "")'
        }
        runners_api_call GET "/users?provider=openid_connect&extern_uid=${PW_USER}"
        owner_id=$(printf '%s' "${api_body}" | first_user_id)
        if [ -z "${owner_id}" ]; then
            runners_api_call GET "/users?username=${PW_USER}"
            owner_id=$(printf '%s' "${api_body}" | first_user_id)
            if [ -n "${owner_id}" ]; then
                runners_api_call PUT "/users/${owner_id}" --data "provider=openid_connect" --data-urlencode "extern_uid=${PW_USER}"
                if [ "${api_status}" = "200" ]; then
                    echo "::notice::GitLab account ${PW_USER} (user ${owner_id}) now signs in with ${oidc_display_name}"
                else
                    echo "::warning::GitLab account ${PW_USER} exists without an ${oidc_display_name} identity and could not be given one (HTTP ${api_status}); a sign-in with ${oidc_display_name} creates a second account"
                fi
            else
                # The platform knows the user's email; the run's key may read it
                email=$(pw api users 2>/dev/null | python3 -c '
import json, sys
try:
    for u in json.load(sys.stdin).get("users", []):
        if u.get("username") == sys.argv[1]:
            print(u.get("email", ""))
            break
except Exception:
    pass' "${PW_USER}")
                if [ -z "${email}" ]; then
                    email="${PW_USER}@${platform_host}"
                    echo "::warning::The platform did not tell this run your email; the GitLab account ${PW_USER} gets ${email} (change it in GitLab's profile)"
                fi
                runners_api_call POST /users \
                    --data-urlencode "username=${PW_USER}" --data-urlencode "name=${PW_USER}" \
                    --data-urlencode "email=${email}" \
                    --data "provider=openid_connect" --data-urlencode "extern_uid=${PW_USER}" \
                    --data "force_random_password=true" --data "reset_password=false" --data "skip_confirmation=true"
                owner_id=$(printf '%s' "${api_body}" | json_get id)
                if [ "${api_status}" = "201" ] && [ -n "${owner_id}" ]; then
                    echo "::notice::Created the GitLab account ${PW_USER} (user ${owner_id}) for your first sign-in with ${oidc_display_name}"
                else
                    owner_id=""
                    echo "::warning::Could not create the GitLab account ${PW_USER} ahead of its first sign-in (HTTP ${api_status}): $(printf '%s' "${api_body}" | json_get message). Sign in with ${oidc_display_name} and start again: the account is then made Owner of ${group_path}"
                fi
            fi
        fi
        if [ -n "${owner_id}" ]; then
            runners_api_call POST "/groups/${group_id}/members" --data "user_id=${owner_id}" --data "access_level=50"
            if [ "${api_status}" = "409" ]; then
                runners_api_call PUT "/groups/${group_id}/members/${owner_id}" --data "access_level=50"
            fi
            case "${api_status}" in
                200|201) echo "::notice::${PW_USER} is Owner of the group ${group_path}" ;;
                *) echo "::warning::${PW_USER} could not be made Owner of ${group_path} (HTTP ${api_status}): $(printf '%s' "${api_body}" | json_get message)" ;;
            esac
        fi
    fi
    export runner_type=group_type runner_scope_id="${group_id}"
    echo "::notice::The runners take the pipelines of the group ${group_path} only (${public_url}${group_path}); create your projects there"
}

# Everything after the boot goes through the API with a root token that lives
# for this launcher only; it is revoked at the end. The token never enters
# the trace
gitlab_setup() {
    set +x
    local admin_token
    admin_token=$(gitlab_exec gitlab-rails runner \
        "t = User.find_by_username('root').personal_access_tokens.create!(scopes: ['api', 'create_runner'], name: 'activate-workflow-${PW_RUN_SLUG}', expires_at: 1.day.from_now); puts t.token" 2>/dev/null | tail -n 1)
    if [ -z "${admin_token}" ]; then
        fail "Could not create a root API token in the container (gitlab-rails runner failed)"
    fi
    export api_base="${api}" api_host="${host}" api_token="${admin_token}"

    if [ -s "${service_license_file}" ]; then
        local marker="${service_rundir}/.license-$(sha256sum "${service_license_file}" | cut -c1-16)"
        if [ -f "${marker}" ]; then
            echo "::notice::The license of the form is already applied to ${service_rundir}"
        else
            runners_api_call POST /license --data-urlencode "license@${service_license_file}"
            if [ "${api_status}" = "201" ]; then
                touch "${marker}"
                echo "::notice::License applied: plan $(printf '%s' "${api_body}" | json_get plan), expires $(printf '%s' "${api_body}" | json_get expires_at)"
            else
                echo "::warning::The license was not applied (HTTP ${api_status}): ${api_body}. Add it under Admin -> Settings -> General -> Add License"
            fi
        fi
    fi

    # The owner's runners: group runners of the owner's group, polling this
    # GitLab on its own port (same user, no forwarder needed), with their
    # tokens kept in the run directory for a later start
    local group_id
    gitlab_owner_group
    export runner_url="http://127.0.0.1:${PORT}"
    if ! runners_setup; then
        fail "The CI runners were not started (above)"
    fi
    set +x

    runners_api_call DELETE /personal_access_tokens/self
    unset admin_token api_token
    set -x

    echo "::notice::Sign in as root with the password in ${root_password_file} (first start) or the one you set in GitLab"
    if [ -n "${oidc_client_id}" ]; then
        echo "::notice::Sign in with ${oidc_display_name} from GitLab's own tab (${public_url}users/sign_in): redirect URI ${public_url}users/auth/openid_connect/callback"
    fi
    echo "::notice::Git over HTTP from this host: http://127.0.0.1:${PORT}/<group>/<project>.git; from your machine: pw forward -L ${PORT}:localhost:${PORT} <cluster> (or -L ${service_ssh_port}:localhost:${service_ssh_port} for SSH)"
    echo "::notice::Another user of this GitLab runs their own pipelines by launching this workflow in its runner mode on this cluster with ${public_url} as the GitLab address"

    # Opens the sign-in page to the platform's probe: the run completes from here
    touch "${run_dir}/activate/ready"
    chmod 644 "${run_dir}/activate/ready"
}
