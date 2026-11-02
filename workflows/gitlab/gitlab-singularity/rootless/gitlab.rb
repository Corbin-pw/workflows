# Settings of the single-user image, loaded by /assets/gitlab.rb before
# GITLAB_OMNIBUS_CONFIG and /etc/gitlab/gitlab.rb, which may override them.
#
# The container runs as one unprivileged account, which the bound /etc/passwd
# names git (first, so the account's name is git) and also gitlab-psql,
# gitlab-www, ... Every service is configured to run as git, so that the
# owner Chef checks on a directory (the account's name) is the one it expects
# and PostgreSQL's peer authentication sees the system user git, which its
# user map lets connect as the gitlab role and as itself.
postgresql['username'] = 'git'
postgresql['group'] = 'git'
redis['username'] = 'git'
redis['group'] = 'git'
web_server['username'] = 'git'
web_server['group'] = 'git'
prometheus['username'] = 'git'
prometheus['group'] = 'git'
registry['username'] = 'git'
registry['group'] = 'git'
consul['username'] = 'git'
consul['group'] = 'git'

# The image's OpenSSH needs root; GitLab's own SSH server (gitlab-sshd, part of
# gitlab-shell) runs as git and generates its host keys into
# /var/opt/gitlab/gitlab-sshd
gitlab_sshd['enable'] = true
gitlab_sshd['listen_address'] = '127.0.0.1:2222'
