# Manages the openvox-agent launchd plist on macOS and reloads the job when
# it changes. launchd only reads EnvironmentVariables when a job is loaded,
# so a changed plist does nothing until the job is booted out and
# bootstrapped again.
#
# $reload_method:
#   'helper' - hand the reload to a one-shot launchd job, so it survives the
#              agent being booted out (the recommended way)
#   'inline' - bootout + bootstrap straight from the exec (kept only to show
#              what goes wrong)
class profile::puppet_launchd (
  Enum['helper', 'inline'] $reload_method = 'helper',
  Integer[0] $reload_delay = 60,
  Hash[String, String] $environment_variables = {
    'LANG'             => 'en_US.UTF-8',
    'OS_ACTIVITY_MODE' => 'disable',
  },
) {
  $plist = '/Library/LaunchDaemons/org.voxpupuli.puppet.plist'
  $helper_label = 'org.voxpupuli.puppet-reload'
  $helper_plist = "/Library/LaunchDaemons/${helper_label}.plist"

  file { $plist:
    ensure  => file,
    owner   => 'root',
    group   => 'wheel',
    mode    => '0644',
    content => epp('profile/puppet.plist.epp', {
      'environment_variables' => $environment_variables,
    }),
    notify  => Exec['reload puppet launchd job'],
  }

  if $reload_method == 'helper' {
    file { $helper_plist:
      ensure  => file,
      owner   => 'root',
      group   => 'wheel',
      mode    => '0644',
      content => epp('profile/puppet-reload.plist.epp', {
        'label' => $helper_label,
        'plist' => $plist,
        'delay' => $reload_delay,
      }),
    }

    # Clear out a helper left over from an earlier reload, then load it.
    # RunAtLoad starts it straight away; it sleeps so this run can finish.
    exec { 'reload puppet launchd job':
      command     => "/bin/launchctl bootout system/${helper_label} 2>/dev/null; /bin/launchctl bootstrap system ${helper_plist}",
      provider    => shell,
      refreshonly => true,
      require     => File[$helper_plist],
    }
  } else {
    exec { 'reload puppet launchd job':
      command     => "/bin/launchctl bootout system/puppet; /bin/launchctl bootstrap system ${plist}",
      provider    => shell,
      refreshonly => true,
    }
  }
}
