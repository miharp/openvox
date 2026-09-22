#!/bin/bash
# Runs the real agent daemon (forking mode) against an unreachable A-only
# server name and reports whether the forked runs crash.
# usage: daemon_test.sh <label> <crl_refresh_interval> <seconds>
set -u
label=$1; crl_interval=$2; duration=$3
server=${SERVER:-10.255.255.1.nip.io}
root=$(mktemp -d)
puppet=/opt/puppetlabs/bin/puppet
ruby=/opt/puppetlabs/puppet/bin/ruby
mkdir -p "$root/conf" "$root/var" "$root/log" "$root/run"
"$ruby" "$(dirname "$0")/fake_ssl.rb" "$root/conf/ssl" repro538 >/dev/null
cat > "$root/conf/puppet.conf" <<CONF
[main]
certname = repro538
server = $server
runinterval = 15
splay = false
http_connect_timeout = 3s
crl_refresh_interval = $crl_interval
ca_refresh_interval = 1d
usecacheonfailure = false
CONF
"$puppet" agent --no-daemonize --verbose --logdest console \
  --confdir "$root/conf" --vardir "$root/var" --logdir "$root/log" --rundir "$root/run" \
  > "$root/agent.log" 2>&1 &
pid=$!
sleep "$duration"
kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
bugs=$(grep -c "\[BUG\]" "$root/agent.log")
refresh=$(grep -c "Failed to refresh CRL\|automatically renew\|Failed to refresh CA" "$root/agent.log")
echo "daemon [$label] crl_refresh_interval=$crl_interval: parent pre-fork network attempts=$refresh, child ruby [BUG] crashes=$bugs"
# one letter per event, in order: R = parent pre-fork network attempt,
# ok = forked run failed normally at the connection, CRASH = forked run died
timeline=$(sed $'s/\x1b\\[[0-9;]*m//g' "$root/agent.log" | awk '
  /Failed to refresh CRL|automatically renew|Failed to refresh CA/ {printf "R "}
  /\[BUG\]/ {printf "CRASH "}
  /Not using cache on failed catalog/ {printf "ok "}
')
echo "  timeline: $timeline"
echo "  log: $root/agent.log" >&2
