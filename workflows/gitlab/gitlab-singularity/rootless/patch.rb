# Edits to the Linux package that let it run as an unprivileged user, applied
# once while the image is built (gitlab.def %post). Each edit names the exact
# text it replaces, so a GitLab version that moved it fails the build instead
# of shipping an image that fails at its first start.

def patch(path, from, to)
  text = File.read(path)
  return if text.include?(to)

  found = from.is_a?(Regexp) ? text.match?(from) : text.include?(from)
  raise "#{path}: #{from.inspect} not found" unless found

  File.write(path, text.sub(from, to))
end

# gitlab-ctl refuses "reconfigure" to anyone but root; nothing in it needs root
# once the accounts are the caller's
patch('/opt/gitlab/bin/gitlab-ctl',
      /^if \[ "\$1" == "reconfigure" \] && \[ "\$UID" != "0" \]; then\n.*?\nfi\n/m,
      "# single-user image: reconfigure runs as the user\n")

# Every reconfigure first empties the cached node state with "rm -rf <dir>/";
# the directory is a symlink into the data volume, which rm cannot remove
omnibus_ctl = Dir['/opt/gitlab/embedded/lib/ruby/gems/*/gems/omnibus-ctl-*/lib/omnibus-ctl.rb'].first
patch(omnibus_ctl,
      'run_command("rm -rf #{node_cache_path}")',
      'run_command("rm -rf #{node_cache_path}*")')

# The first boot re-links the PostgreSQL binaries into /opt/gitlab/embedded/bin,
# which is read-only here; the image ships them linked to its default version
patch('/opt/gitlab/embedded/cookbooks/postgresql/recipes/bin.rb',
      %q{FileUtils.ln_sf(pg_bin, "#{node['package']['install-dir']}/embedded/bin/#{File.basename(pg_bin)}")},
      %q{pg_link = "#{node['package']['install-dir']}/embedded/bin/#{File.basename(pg_bin)}"; FileUtils.ln_sf(pg_bin, pg_link) unless File.symlink?(pg_link) && File.readlink(pg_link) == pg_bin})

# The single-user settings load before GITLAB_OMNIBUS_CONFIG, which may
# override them. Evaluated in place, not with from_file: a nested from_file
# turns the DSL's auto-vivification off when it returns, and the next
# nested key of GITLAB_OMNIBUS_CONFIG (nginx['status']['enable']) fails
patch('/assets/gitlab.rb',
      'eval ENV["GITLAB_OMNIBUS_CONFIG"]',
      "eval File.read('/assets/rootless/gitlab.rb'), binding, '/assets/rootless/gitlab.rb'\neval ENV[\"GITLAB_OMNIBUS_CONFIG\"]")

# A templatesymlink that is turned off (SMTP settings, a Redis instance of its
# own) deletes its target and the link in the Rails tree; the tree is
# read-only here and holds every such link from the build, so only the target
# goes: Rails skips a configuration file whose link dangles, and turning the
# setting on again finds the link in place
patch('/opt/gitlab/embedded/cookbooks/package/resources/templatesymlink.rb',
      "\n  link new_resource.link_from do\n    action :delete\n  end\nend",
      "\n  # single-user image: the link in the read-only Rails tree stays\nend")

# Chef's directory resource insists on a writable parent even when the
# directory exists; the package's volumes (/etc/gitlab, /var/opt/gitlab,
# /var/log/gitlab) and the redirected install paths exist as mounts and
# symlinks under read-only parents
patch(Dir['/opt/gitlab/embedded/lib/ruby/gems/*/gems/chef-*/lib/chef/provider/directory.rb'].first,
      "          a.assertion do\n            if new_resource.recursive\n              # find the lowest-level directory in new_resource.path that already exists",
      "          a.assertion do\n            next true if ::File.directory?(new_resource.path) # single-user image: an existing directory needs no writable parent\n            if new_resource.recursive\n              # find the lowest-level directory in new_resource.path that already exists")

# Rails refuses a dangling link among its initializers, so the one
# templatesymlink there (smtp_settings.rb) is a file in the image that loads
# the volume's copy when it exists; the resource then writes the copy and
# leaves the file alone
patch('/opt/gitlab/embedded/cookbooks/package/resources/templatesymlink.rb',
      "    to new_resource.link_to\n    action :create\n  end",
      "    to new_resource.link_to\n    action :create\n    not_if { ::File.exist?(new_resource.link_from) && !::File.symlink?(new_resource.link_from) } # single-user image: a file stands in for the link\n  end")
