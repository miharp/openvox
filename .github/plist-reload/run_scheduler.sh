#!/bin/bash
# Tests voxpupuli/puppet-puppet_run_scheduler (cron mode) on macOS: the stock
# daemon applies the class, installs the root cron job and stops itself;
# cron must then run the agent at the scheduled minute.
# Expects the module and stdlib in ./vendor.
# usage: sudo run_scheduler.sh <watch_seconds>
set -u
watch=$1
here=$(cd "$(dirname "$0")" && pwd)
ruby=/opt/puppetlabs/puppet/bin/ruby
daemon_plist=/Library/LaunchDaemons/org.voxpupuli.puppet.plist
logdir=/var/log/puppetlabs/puppet
catalog=/opt/puppetlabs/puppet/cache/client_data/catalog/ci.json
summary=/opt/puppetlabs/puppet/cache/state/last_run_summary.yaml

compile() {
  MODULEPATH="$here/vendor" "$ruby" "$here/compile.rb" ci "class { 'puppet_run_scheduler': run_interval => '15m', start_time => '$1' }" "$catalog" >/dev/null
}
cron_minutes() {
  "$ruby" -rjson -e 'r = JSON.parse(File.read(ARGV[0]))["resources"].find { |x| x["type"] == "Cron" }; puts Array(r["parameters"]["minute"]).join(",")' "$catalog"
}
summary_time() { [ -f "$summary" ] && awk '/last_run:/ {print $2}' "$summary"; }

launchctl bootout system/puppet 2>/dev/null
crontab -r 2>/dev/null
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
rm -rf /etc/puppetlabs/puppet/ssl /opt/puppetlabs/puppet/cache/state
"$ruby" "$here/fake_ssl.rb" /etc/puppetlabs/puppet/ssl ci >/dev/null
mkdir -p "$(dirname "$catalog")"
rm -f "$logdir/puppet.log"

# The first cron minute is the module's fqdn_rand splay (mod 15). Shift
# start_time so that it lands about two minutes from now.
compile 00:00
splay=$(cron_minutes | cut -d, -f1)
target=$(( (10#$(date +%M) + 2) % 15 ))
offset=$(( ((target - splay) % 15 + 15) % 15 ))
compile "$(printf '00:%02d' "$offset")"
echo "== splay $splay, start_time 00:$(printf %02d "$offset"), cron minutes: $(cron_minutes), now: $(date +%H:%M:%S)"

launchctl bootstrap system "$daemon_plist"
echo "   $(date +%H:%M:%S) t=0 daemon loaded"
last="" first_cron_run=""
for ((t = 5; t <= watch; t += 5)); do
  sleep 5
  daemon=$(launchctl print system/puppet >/dev/null 2>&1 && echo loaded || echo GONE)
  cronjob=$(crontab -l 2>/dev/null | grep -c puppet-run-scheduler)
  agents=$(pgrep -f 'agent --onetime' | wc -l | tr -d ' ')
  now="daemon=$daemon cron_entries=$cronjob onetime_agents_running=$agents last_run=$(summary_time)"
  [ "$now" != "$last" ] && echo "   $(date +%H:%M:%S) t=${t}s $now"
  last=$now
  if [ "$daemon" = GONE ] && [ "$agents" -gt 0 ] && [ -z "$first_cron_run" ]; then first_cron_run=$(date +%H:%M:%S); fi
done

disabled=$(launchctl print-disabled system | grep -E '"puppet" => (disabled|true)' >/dev/null && echo yes || echo no)
echo "== root crontab:"
crontab -l
echo "== last_run_summary.yaml time section:"
sed -n '/^time:/,/^[a-z]/p' "$summary" 2>/dev/null | grep -E 'last_run|total'
echo "== puppet.log (daemon only; cron runs go to /dev/null):"
sed $'s/\x1b\\[[0-9;]*m//g' "$logdir/puppet.log" 2>/dev/null | grep -vE 'Using (cached catalog|environment)|Caching catalog|Applying configuration'
echo "== crash reports: $(ls /Library/Logs/DiagnosticReports 2>/dev/null | grep -c 'ruby.*\.ips$')"

if [ "$daemon" = GONE ] && [ "$disabled" = yes ] && [ "$cronjob" = 1 ] && [ -n "$first_cron_run" ] && [ -n "$(summary_time)" ]; then
  verdict=PASS
else
  verdict=FAIL
fi
echo "RESULT [puppet_run_scheduler cron]: $verdict - daemon $daemon, disabled: $disabled, cron entries: $cronjob, first cron-started agent seen: ${first_cron_run:-never}, last_run: $(summary_time)"
