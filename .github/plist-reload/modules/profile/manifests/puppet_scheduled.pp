# Runs the openvox agent on macOS as a scheduled launchd job
# (puppet agent --onetime at fixed minutes) instead of the long-running
# daemon. Every run is a fresh process, so no long-lived parent can get into
# the state that crashes its forked children on macOS 26 (#538).
#
# $reload_method decides how a change to the schedule is picked up. The run
# doing the change is the job being reloaded, so a plain bootout kills it:
#   'inline' - reload from the exec; AbandonProcessGroup keeps the exec's
#              shell alive after launchd stops the agent
#   'helper' - hand the reload to a one-shot launchd job
class profile::puppet_scheduled (
  Array[Integer[0, 59], 1] $minutes = [fqdn_rand(30), fqdn_rand(30) + 30],
  Enum['inline', 'helper'] $reload_method = 'inline',
  Integer[0] $reload_delay = 60,
) {
  $label = 'org.voxpupuli.puppet-run'
  $plist = "/Library/LaunchDaemons/${label}.plist"
  $helper_label = 'org.voxpupuli.puppet-reload'
  $helper_plist = "/Library/LaunchDaemons/${helper_label}.plist"

  file { $plist:
    ensure  => file,
    owner   => 'root',
    group   => 'wheel',
    mode    => '0644',
    content => epp('profile/puppet-run.plist.epp', {
      'label'   => $label,
      'minutes' => $minutes.sort,
    }),
  }

  if $reload_method == 'helper' {
    file { $helper_plist:
      ensure  => file,
      owner   => 'root',
      group   => 'wheel',
      mode    => '0644',
      content => epp('profile/puppet-reload.plist.epp', {
        'label'        => $helper_label,
        'target_label' => $label,
        'target_plist' => $plist,
        'delay'        => $reload_delay,
      }),
      before  => Exec['reload puppet-run job'],
    }
    $reload = "/bin/launchctl bootout system/${helper_label} 2>/dev/null; /bin/launchctl bootstrap system ${helper_plist}"
  } else {
    # bootout returns before the job has exited, and bootstrap fails with
    # "5: Input/output error" until it is gone, so wait for it and retry.
    $reload = @("CMD"/L)
      /bin/launchctl bootout system/${label}; \
      for i in $(seq 60); do /bin/launchctl print system/${label} >/dev/null 2>&1 || break; sleep 1; done; \
      for i in $(seq 10); do /bin/launchctl bootstrap system ${plist} && break; sleep 3; done
      | CMD
  }

  # Only reloads a job that is already loaded; a first install is left to
  # the load exec below.
  exec { 'reload puppet-run job':
    command     => "/bin/launchctl print system/${label} >/dev/null 2>&1 || exit 0; ${reload}",
    provider    => shell,
    refreshonly => true,
    subscribe   => File[$plist],
  }

  exec { 'load puppet-run job':
    command => "/bin/launchctl bootstrap system ${plist}",
    unless  => "/bin/launchctl print system/${label}",
    require => Exec['reload puppet-run job'],
  }

  # Last, because when the daemon is the one applying this it stops itself
  # here and the rest of its run is lost. The scheduled job takes over.
  service { 'puppet':
    ensure  => stopped,
    enable  => false,
    require => Exec['load puppet-run job'],
  }
}
