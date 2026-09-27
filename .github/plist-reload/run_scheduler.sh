#!/bin/bash
# Tests voxpupuli/puppet-puppet_run_scheduler (cron mode) on macOS: the stock
# daemon applies the class, installs the root cron job and stops itself;
# cron must then run the agent at the scheduled minute.
# Expects the module and stdlib in ./vendor.
# usage: sudo run_scheduler.sh <seconds_to_watch_after_first_cron_minute>
set -u
after=$1
here=$(cd "$(dirname "$0")" && pwd)
ruby=/opt/puppetlabs/puppet/bin/ruby
daemon_plist=/Library/LaunchDaemons/org.voxpupuli.puppet.plist
logdir=/var/log/puppetlabs/puppet
catalog=/opt/puppetlabs/puppet/cache/client_data/catalog/ci.json
summary=$(/opt/puppetlabs/bin/puppet config print lastrunfile)

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
echo "== cron minutes with start_time 00:00: $(cron_minutes)"
splay=$(cron_minutes | cut -d, -f1)
target=$(( (10#$(date +%M) + 2) % 15 ))
offset=$(( ((target - splay) % 15 + 15) % 15 ))
compile "$(printf '00:%02d' "$offset")"
echo "== splay $splay, start_time 00:$(printf %02d "$offset"), cron minutes: $(cron_minutes), now: $(date +%H:%M:%S), lastrunfile: $summary"

# Watch until $after seconds past the first cron minute that is actually in
# the catalog, whatever the offset above achieved.
now_s=$(( 10#$(date +%M) * 60 + 10#$(date +%S) ))
wait_s=3600
for m in $(cron_minutes | tr , ' '); do
  d=$(( (m * 60 - now_s + 3600) % 3600 ))
  [ "$d" -lt 30 ] && d=$((d + 3600))
  [ "$d" -lt "$wait_s" ] && wait_s=$d
done
watch=$(( wait_s + after ))
echo "== first cron minute in ${wait_s}s, watching for ${watch}s"
start_epoch=$(date +%s)

launchctl bootstrap system "$daemon_plist"
echo "   $(date +%H:%M:%S) t=0 daemon loaded"
last="" first_cron_run="" first_cron_epoch=0
for ((t = 5; t <= watch; t += 5)); do
  sleep 5
  daemon=$(launchctl print system/puppet >/dev/null 2>&1 && echo loaded || echo GONE)
  cronjob=$(crontab -l 2>/dev/null | grep -c puppet-run-scheduler)
  agents=$(pgrep -f 'agent --onetime' | wc -l | tr -d ' ')
  now="daemon=$daemon cron_entries=$cronjob onetime_agents_running=$agents last_run=$(summary_time)"
  [ "$now" != "$last" ] && echo "   $(date +%H:%M:%S) t=${t}s $now"
  last=$now
  if [ "$daemon" = GONE ] && [ "$agents" -gt 0 ] && [ -z "$first_cron_run" ]; then first_cron_run=$(date +%H:%M:%S); first_cron_epoch=$(date +%s); fi
done

disabled=$(launchctl print-disabled system | grep -E '"puppet" => (disabled|true)' >/dev/null && echo yes || echo no)
echo "== root crontab:"
crontab -l
echo "== last_run_summary.yaml time section:"
grep -E '^\s+(last_run|failure|failed|total|config_retrieval):' "$summary" 2>/dev/null
last_run_s=$(summary_time)
[ -n "$last_run_s" ] && echo "   last_run = $(date -r "$last_run_s" +%H:%M:%S)"
echo "== puppet.log (daemon only; cron runs go to /dev/null):"
sed $'s/\x1b\\[[0-9;]*m//g' "$logdir/puppet.log" 2>/dev/null | grep -vE 'Using (cached catalog|environment)|Caching catalog|Applying configuration'
echo "== unified log from the agent since the test started (cron runs log to syslog):"
log show --start "$(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S')" --style compact --predicate 'process == "ruby" OR process == "puppet"' 2>/dev/null | grep -v '^Timestamp' | cut -c1-220 | tail -40
echo "== crash reports: $(ls /Library/Logs/DiagnosticReports 2>/dev/null | grep -c 'ruby.*\.ips$')"

if [ "$daemon" = GONE ] && [ "$disabled" = yes ] && [ "$cronjob" = 1 ] && [ -n "$first_cron_run" ] && [ "${last_run_s:-0}" -ge $((first_cron_epoch - 10)) ]; then
  verdict=PASS
else
  verdict=FAIL
fi
echo "RESULT [puppet_run_scheduler cron]: $verdict - daemon $daemon, disabled: $disabled, cron entries: $cronjob, first cron-started agent seen: ${first_cron_run:-never}, last_run: ${last_run_s:+$(date -r "$last_run_s" +%H:%M:%S)}"
