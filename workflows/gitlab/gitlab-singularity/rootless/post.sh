#!/bin/bash
# Build step of the single-user image (gitlab.def %post): the edits that let
# the Linux package run as one unprivileged account from a read-only image.
# What the package writes under /opt/gitlab becomes symlinks into
# /var/opt/gitlab/.rootless, the data volume; image content those paths held
# is kept under /opt/gitlab/.rootless-dist for init-rootless to seed from.
set -euo pipefail

rootless=/assets/rootless
dist=/opt/gitlab/.rootless-dist
mkdir -p "${dist}"

/opt/gitlab/embedded/bin/ruby "${rootless}/patch.rb"

if ! [ -e /opt/gitlab/embedded/bin/chpst.real ]; then
    mv /opt/gitlab/embedded/bin/chpst /opt/gitlab/embedded/bin/chpst.real
fi
install -m 755 "${rootless}/chpst" /opt/gitlab/embedded/bin/chpst
install -m 755 "${rootless}/init-rootless" /assets/init-rootless

# The image's OpenSSH service needs root; gitlab-sshd replaces it
rm -rf /opt/gitlab/sv/sshd /opt/gitlab/etc/sshd

# Every bind destination exists in the image: a runtime without an overlay
# or underlay (a hardened node) creates none
mkdir -p /etc/gitlab /var/opt/gitlab /var/log/gitlab /var/tmp /tmp

redirect() {
    # redirect <image path> <name under /var/opt/gitlab/.rootless> [seed]
    local path=$1 name=$2
    if [ "$(readlink "${path}" 2>/dev/null)" = "/var/opt/gitlab/.rootless/${name}" ]; then
        return
    fi
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        if [ "${3:-}" = seed ]; then
            mv "${path}" "${dist}/${name}"
        else
            rm -rf "${path}"
        fi
    fi
    mkdir -p "$(dirname "${path}")"
    ln -s "/var/opt/gitlab/.rootless/${name}" "${path}"
}
redirect /opt/gitlab/sv sv
redirect /opt/gitlab/service service
redirect /opt/gitlab/init init
redirect /opt/gitlab/etc etc seed
redirect /opt/gitlab/var var
redirect /opt/gitlab/embedded/nodes nodes
redirect /opt/gitlab/embedded/etc embedded-etc
redirect /opt/gitlab/embedded/cookbooks/cache chef-cache
redirect /opt/gitlab/embedded/ssl/certs ssl-certs seed
redirect /opt/gitlab/embedded/cookbooks/dna.json dna.json seed
redirect /opt/gitlab/embedded/cookbooks/cinc_guid cinc_guid
redirect /opt/gitlab/embedded/service/gitlab-rails/db/structure.sql structure.sql seed

# The links the configuration run creates in the Rails and gitlab-shell trees,
# made here because those trees are read-only at run time
rails=/opt/gitlab/embedded/service/gitlab-rails
etc=/var/opt/gitlab/gitlab-rails/etc
for f in database.yml click_house.yml managed_settings.yml secrets.yml resque.yml redis.yml cable.yml session_store.yml gitlab.yml \
         redis.cache.yml redis.queues.yml redis.shared_state.yml redis.trace_chunks.yml redis.rate_limiting.yml \
         redis.sessions.yml redis.repository_cache.yml redis.cluster_rate_limiting.yml redis.workhorse.yml; do
    ln -sfn "${etc}/${f}" "${rails}/config/${f}"
done
# Rails refuses a dangling link among its initializers (the one it would be
# while SMTP is off), so this one is a file that loads the volume's copy
rm -f "${rails}/config/initializers/smtp_settings.rb"
cat > "${rails}/config/initializers/smtp_settings.rb" <<'RUBY'
# single-user image (workflows/gitlab): the configuration run writes the SMTP
# settings into the data volume when gitlab_rails['smtp_enable'] is on; the
# Rails tree is read-only, so this file stands in for the link it would make
smtp_settings = '/var/opt/gitlab/gitlab-rails/etc/smtp_settings.rb'
load smtp_settings if File.exist?(smtp_settings)
RUBY
chmod 644 "${rails}/config/initializers/smtp_settings.rb"
for s in workhorse shell incoming_email service_desk_email pages kas knowledge_graph; do
    ln -sfn "${etc}/gitlab_${s}_secret" "${rails}/.gitlab_${s}_secret"
done
rm -rf "${rails}/tmp" "${rails}/log" "${rails}/public/uploads"
ln -s /var/opt/gitlab/gitlab-rails/tmp "${rails}/tmp"
ln -s /var/log/gitlab/gitlab-rails "${rails}/log"
ln -s /var/opt/gitlab/gitlab-rails/uploads "${rails}/public/uploads"
shell=/opt/gitlab/embedded/service/gitlab-shell
ln -sfn /var/opt/gitlab/gitlab-shell/config.yml "${shell}/config.yml"
ln -sfn "${rails}/.gitlab_shell_secret" "${shell}/.gitlab_shell_secret"

echo "single-user image prepared"
