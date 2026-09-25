file { '/tmp/managed_file':
  ensure => file,
  source => 'http://127.0.0.1:8000/artifact',
  notify => Exec['on_change'],
}

exec { 'on_change':
  command     => '/bin/echo NOTIFY_FIRED',
  path        => '/usr/bin:/bin',
  refreshonly => true,
}
