#!/bin/bash
# Tests profile::puppet_scheduled under launchd in two phases:
#   1. switchover: the stock daemon applies the class, loads the scheduled
#      job and stops itself; the scheduled job must take over
#   2. schedule change: a scheduled run rewrites its own plist and reloads
#      its own job; the job must come back with the new schedule
# usage: sudo run_scheduled.sh <inline|helper> <reload_delay> <phase1_seconds> <phase2_seconds>
set -u
method=$1; delay=$2; watch1=$3; watch2=$4
here=$(cd "$(dirname "$0")" && pwd)
ruby=/opt/puppetlabs/puppet/bin/ruby
daemon_plist=/Library/LaunchDaemons/org.voxpupuli.puppet.plist
run=org.voxpupuli.puppet-run
run_plist=/Library/LaunchDaemons/$run.plist
helper=org.voxpupuli.puppet-reload
logdir=/var/log/puppetlabs/puppet
catalog=/opt/puppetlabs/puppet/cache/client_data/catalog/ci.json
every_minute="[$(seq -s, 0 59)]"
even_minutes="[$(seq -s, 0 2 58)]"

field() { launchctl print "system/$1" 2>/dev/null | awk -F ' = ' -v k="$2" '{sub(/^[ \t]+/, "", $1)} $1 == k {print $2; exit}'; }
state_of() { launchctl print "system/$1" >/dev/null 2>&1 && echo "loaded(pid=$(field "$1" pid) runs=$(field "$1" runs) last_exit=$(field "$1" 'last exit code'))" || echo GONE; }
minutes_in() { /usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval' "$run_plist" 2>/dev/null | grep -c Minute; }
compile() {
  "$ruby" "$here/compile.rb" ci "class { 'profile::puppet_scheduled': minutes => $1, reload_method => '$method', reload_delay => $delay }" "$catalog"
}
# Sets reloaded=yes when launchd's run counter for the scheduled job drops,
# which only happens when the job is booted out and bootstrapped again.
watch() {
  local last="" now prev="" cur
  reloaded=no
  for ((t = 5; t <= $1; t += 5)); do
    sleep 5
    cur=$(field $run runs)
    [ -n "$prev" ] && [ -n "$cur" ] && [ "$cur" -lt "$prev" ] && reloaded=yes
    [ -n "$cur" ] && prev=$cur
    now="daemon=$(state_of puppet) run=$(state_of $run) helper=$(launchctl print "system/$helper" >/dev/null 2>&1 && echo loaded || echo -)"
    [ "$now" != "$last" ] && echo "   $(date +%H:%M:%S) t=${t}s $now"
    last=$now
  done
}

launchctl bootout system/puppet 2>/dev/null
launchctl bootout "system/$run" 2>/dev/null
launchctl bootout "system/$helper" 2>/dev/null
rm -f "$run_plist" "/Library/LaunchDaemons/$helper.plist"
cat > /etc/puppetlabs/puppet/puppet.conf <<CONF
[main]
certname = ci
server = 10.255.255.1.nip.io
runinterval = 30
splay = false
use_cached_catalog = true
report = false
http_connect_timeout = 3s
CONF
rm -rf /etc/puppetlabs/puppet/ssl
"$ruby" "$here/fake_ssl.rb" /etc/puppetlabs/puppet/ssl ci >/dev/null
mkdir -p "$(dirname "$catalog")"
rm -f "$logdir"/puppet.log "$logdir"/puppet-reload.log

echo "== phase 1: daemon switches itself over to the scheduled job (every minute)"
compile "$every_minute"
launchctl bootstrap system "$daemon_plist"
echo "   $(date +%H:%M:%S) t=0 daemon=$(state_of puppet)"
watch "$watch1"
daemon1=$(launchctl print system/puppet >/dev/null 2>&1 && echo loaded || echo GONE)
disabled1=$(launchctl print-disabled system | grep -E '"puppet" => (disabled|true)' >/dev/null && echo yes || echo no)
runs1=$(field $run runs)
echo "   daemon $daemon1, disabled in launchd: $disabled1, scheduled runs so far: ${runs1:-none}"
if [ "$daemon1" = GONE ] && [ "$disabled1" = yes ] && [ "${runs1:-0}" -ge 1 ]; then p1=PASS; else p1=FAIL; fi

echo "== phase 2: a scheduled run changes the schedule (even minutes) and reloads its own job"
compile "$even_minutes"
watch "$watch2"
count=$(minutes_in)
state2=$(state_of $run)
runs2=$(field $run runs)
echo "   plist minutes: $count, job: $state2, reloaded: $reloaded"
if [ "$count" = 30 ] && [ "$state2" != GONE ] && [ "$reloaded" = yes ]; then p2=PASS; else p2=FAIL; fi

echo "== puppet.log:"
sed $'s/\x1b\\[[0-9;]*m//g' "$logdir/puppet.log" 2>/dev/null | grep -vE 'Using (cached catalog|environment)|Caching catalog|Applying configuration'
echo "== puppet-reload.log:"
cat "$logdir/puppet-reload.log" 2>/dev/null
echo "== launchctl print system/$run:"
launchctl print "system/$run" 2>&1 | grep -E 'state|runs|last exit|abandon|event' || true

echo "RESULT [$method] phase 1 switchover: $p1 - daemon $daemon1, disabled: $disabled1, scheduled runs: ${runs1:-none}"
echo "RESULT [$method] phase 2 reload: $p2 - job $state2, plist minutes: $count, reloaded: $reloaded, runs at end of phase 1/2: ${runs1:-none}/${runs2:-none}"
