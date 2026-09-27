#!/bin/bash
# Loads the stock agent plist under launchd, lets the daemon apply a cached
# catalog of profile::puppet_launchd (which rewrites the plist and fires the
# reload exec from inside the agent's own run), then reports whether the job
# came back with the new environment.
# usage: sudo run_test.sh <inline|helper> <reload_delay> <watch_seconds>
set -u
method=$1; delay=$2; watch=$3
here=$(cd "$(dirname "$0")" && pwd)
ruby=/opt/puppetlabs/puppet/bin/ruby
plist=/Library/LaunchDaemons/org.voxpupuli.puppet.plist
helper=org.voxpupuli.puppet-reload
logdir=/var/log/puppetlabs/puppet
certname=ci

pid_of() { launchctl print system/puppet 2>/dev/null | awk '$1 == "pid" {print $3}'; }
loaded() { launchctl print system/puppet >/dev/null 2>&1 && echo loaded || echo GONE; }
has_env() { launchctl print system/puppet 2>/dev/null | grep -q 'OS_ACTIVITY_MODE => disable' && echo yes || echo no; }

launchctl bootout system/puppet 2>/dev/null
launchctl bootout "system/$helper" 2>/dev/null
rm -f "/Library/LaunchDaemons/$helper.plist"

cat > /etc/puppetlabs/puppet/puppet.conf <<CONF
[main]
certname = $certname
server = 10.255.255.1.nip.io
runinterval = 30
splay = false
use_cached_catalog = true
report = false
http_connect_timeout = 3s
CONF
rm -rf /etc/puppetlabs/puppet/ssl
"$ruby" "$here/fake_ssl.rb" /etc/puppetlabs/puppet/ssl "$certname" >/dev/null
catdir=/opt/puppetlabs/puppet/cache/client_data/catalog
mkdir -p "$catdir"
"$ruby" "$here/compile.rb" "$certname" "class { 'profile::puppet_launchd': reload_method => '$method', reload_delay => $delay }" "$catdir/$certname.json"

echo "== stock plist, before:"
/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$plist"
rm -f "$logdir"/puppet.log "$logdir"/puppet-reload.log
launchctl bootstrap system "$plist"
sleep 2
pid0=$(pid_of)
echo "== t=0 job $(loaded) pid=$pid0 OS_ACTIVITY_MODE in env: $(has_env)"

last=""
for ((t = 5; t <= watch; t += 5)); do
  sleep 5
  now="job $(loaded) pid=$(pid_of) env=$(has_env) helper=$(launchctl print "system/$helper" >/dev/null 2>&1 && echo loaded || echo -)"
  [ "$now" != "$last" ] && echo "   t=${t}s $now"
  last=$now
done

pid1=$(pid_of)
state=$(loaded); env=$(has_env)
refreshes=$(grep -c "Scheduling refresh of Exec\[reload puppet launchd job\]" "$logdir/puppet.log" 2>/dev/null)
runs=$(grep -c "Applied catalog" "$logdir/puppet.log" 2>/dev/null)

echo "== plist after:"
/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$plist"
echo "== puppet.log:"
sed $'s/\x1b\\[[0-9;]*m//g' "$logdir/puppet.log" 2>/dev/null
echo "== puppet-reload.log:"
cat "$logdir/puppet-reload.log" 2>/dev/null
echo "== launchctl print system/puppet:"
launchctl print system/puppet 2>&1 | grep -E 'state|pid|runs|last exit|OS_ACTIVITY_MODE|LANG' || true

if [ "$state" = loaded ] && [ -n "$pid1" ] && [ "$pid1" != "$pid0" ] && [ "$env" = yes ]; then
  verdict=PASS
else
  verdict=FAIL
fi
echo "RESULT [$method]: $verdict - job $state, pid $pid0 -> ${pid1:-none}, OS_ACTIVITY_MODE in running env: $env, reloads triggered: $refreshes, completed runs: $runs"
