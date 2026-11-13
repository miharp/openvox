#!/bin/bash
set -euo pipefail

echo "=== Installing build deps ==="
apt-get update -qq
apt-get install -y -qq build-essential git libffi-dev libyaml-dev zlib1g-dev >/dev/null

echo "=== Copying repo to a writable location (mount is read-only) ==="
cp -a /app /work

echo "=== Bundle install ==="
export BUNDLE_GEMFILE=/work/Gemfile
export BUNDLE_PATH=/usr/local/bundle
export BUNDLE_WITHOUT="documentation:packaging:release:development"
cd /work
bundle install >/tmp/bundle-install.log 2>&1 || (tail -n 60 /tmp/bundle-install.log && exit 1)

mkdir -p /opt/puppetlabs/puppet /opt/puppetlabs/facter

PUPPET="bundle exec puppet apply --detailed-exitcodes --confdir=/tmp/puppet-conf --vardir=/tmp/puppet-var --logdir=/tmp/puppet-log --codedir=/tmp/puppet-code --publicdir=/opt/puppetlabs/puppet/public"

echo "=== Starting test HTTP server (127.0.0.1:8000) ==="
ruby /test/server.rb &
SERVER_PID=$!
sleep 1

# Expected exit codes are puppet apply --detailed-exitcodes semantics:
# 0 = no changes, 2 = changes applied, 4 = failures, 6 = changes + failures.
run_scenario() {
  local desc="$1" mode="$2" body="$3" expect_notify="$4" expect_exit="$5"
  # Optional: alternate manifest, and an ERE the puppet output must match.
  local manifest="${6:-/test/manifest.pp}" expect_output="${7:-}"
  echo "$mode" > /tmp/server_mode
  echo "$body" > /tmp/server_body

  # Last-Modified / fabricated Time.now checksums are only second-granular
  # (HTTP-date has no sub-second precision). Without a gap here, two
  # scenarios in a row can land in the same wall-clock second and make an
  # otherwise-"changed" comparison spuriously look "in sync" -- a timing
  # artifact of this harness, not a real behavior difference.
  sleep 1.5

  echo
  echo "=================================================================="
  echo "--- $desc"
  echo "    (server mode: $mode, body: $body, expect notify fired: $expect_notify, expect exit: $expect_exit)"
  echo "=================================================================="
  set +e
  OUTPUT=$($PUPPET "$manifest" 2>&1)
  CODE=$?
  set -e
  echo "$OUTPUT" | grep -E "Compiled catalog|content changed|defined content|Triggered|Applied catalog|Error|Warning" || true
  echo "exit code: $CODE"

  if echo "$OUTPUT" | grep -q "Triggered 'refresh'"; then
    FIRED="yes"
  else
    FIRED="no"
  fi

  MISSING=""
  if [ -n "$expect_output" ] && ! echo "$OUTPUT" | grep -qE "$expect_output"; then
    MISSING=" *** and expected output matching /$expect_output/ was not found"
  fi

  if [ "$FIRED" = "$expect_notify" ] && [ "$CODE" = "$expect_exit" ] && [ -z "$MISSING" ]; then
    echo "RESULT: as expected (notify fired: $FIRED, exit: $CODE)"
  else
    echo "RESULT: *** UNEXPECTED *** (notify fired: $FIRED, expected: $expect_notify; exit: $CODE, expected: $expect_exit)$MISSING"
  fi
}

rm -f /tmp/managed_file

run_scenario "1. First apply: no validator headers at all (the #9553 / Artifactory case)" none v1 yes 2
run_scenario "2. Re-apply: same content, still no headers -- THE FIX: should NOT re-notify" none v1 no 0
run_scenario "3. Re-apply: content actually changed, still no headers -- real changes still caught" none v2 yes 2
run_scenario "4. Re-apply: same content, ETag present but unused (no checksum => etag on the resource) -- the raw.githubusercontent.com case, also fixed" etag_unused v2 no 0
run_scenario "5. Re-apply: same content, but Last-Modified churns every request -- KNOWN, UNFIXED gap (header exists, so we never earn a real hash)" last_modified_churn v2 yes 2
run_scenario "6. Re-apply: same content, real sha256 header present -- sanity check, unaffected by this change" sha256 v2 no 0
run_scenario "7. Re-apply: HEAD succeeds with no validators, but the GET fails -- the run must FAIL, never silently report a clean no-change run" get_fails v2 no 4

run_scenario "8. Re-apply: checksum => mtime, still no headers -- explicit opt-out of verification: treated as unchanged, but must WARN that changes can never be detected" none v2 no 0 /test/manifest_mtime.pp "Warning: .*checksum => mtime the file will never be detected as changed"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
echo
echo "Done."
