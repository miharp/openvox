# Docker repro: HTTP `file` source checksum verification fix

This branch is **not meant to be merged**. It exists so anyone reviewing
[fix/http-file-source-checksum-verification](../../tree/fix/http-file-source-checksum-verification)
(fixing [puppetlabs/puppet#9553](https://github.com/puppetlabs/puppet/issues/9553))
can reproduce the manual end-to-end test independently, without trusting a
pasted log.

It runs the real, unmodified `bundle exec puppet apply` from a checked-out
source tree against a small hand-rolled HTTP server that can withhold or
churn cache-validation headers on demand — something a normal static file
server won't do, but which is exactly the shape of origin (e.g. Artifactory
behind Cloudflare) that triggers the bug.

## Prerequisites

- Docker (Docker Desktop or equivalent)
- A local checkout of whichever branch you want to test. To see the fix in
  action: `fix/http-file-source-checksum-verification`. To see the original
  bug reproduce instead, check out `main` (pre-fix) and run the same command.

## Run it

```bash
docker run --rm \
  -v /path/to/your/openvox/checkout:/app:ro \
  -v /path/to/this/docker-repro:/test:ro \
  -v openvox_bundle_cache:/usr/local/bundle \
  ruby:3.3-slim \
  bash /test/entrypoint.sh
```

- `/app` is your openvox checkout, mounted **read-only** — the script copies
  it to a writable location inside the container before running `bundle
  install`, so nothing here can mutate your working tree.
- `/test` is this directory.
- `openvox_bundle_cache` is a named Docker volume that caches installed gems
  across runs, so repeat runs are fast.

First run installs build deps and gems inside the container (a couple of
minutes); subsequent runs with the same cache volume are fast.

## What it does

A single container runs both the test HTTP server (`server.rb`, plain
`TCPServer`, no framework) and eight `puppet apply --detailed-exitcodes`
runs against `manifest.pp` (scenario 8 uses `manifest_mtime.pp`, identical
except for an explicit `checksum => mtime`), flipping the server's response
headers/body between each run via two files the server re-reads on every
request (`/tmp/server_mode`, `/tmp/server_body`). Each scenario asserts
whether `notify` fired and the exact exit code
(0 = no changes, 2 = changes, 4 = failures); scenario 8 additionally
asserts that a specific warning appears in the output.

| # | Scenario | Expected on the fix branch | Expected on `main` (pre-fix) |
|---|---|---|---|
| 1 | First apply, no validator headers at all | file created, notify fires (exit 2) | same |
| 2 | Re-apply, same content, still no headers | **no rewrite, no notify** (exit 0) | rewrite + notify fires anyway (exit 2) — **this is the bug** |
| 3 | Re-apply, content actually changed, still no headers | real change caught, notify fires (exit 2) | same |
| 4 | Re-apply, same content, `ETag` present but unused (no `checksum => etag` on the resource) | **no rewrite, no notify** (exit 0) | rewrite + notify fires anyway (exit 2) — also the bug |
| 5 | Re-apply, same content, but `Last-Modified` churns every request | still spuriously fires (exit 2) — documented, unfixed gap | same |
| 6 | Re-apply, same content, real `X-Checksum-Sha256` header present | no rewrite (exit 0) | same |
| 7 | Re-apply, HEAD succeeds with no validators but the GET fails (500) | run **fails** (exit 4), no notify — "could not verify" is never silently "unchanged" | also fails (exit 4), via a different path: the fabricated mtime forces a content fetch, which then hits the 500 |
| 8 | Re-apply, same content, still no headers, but the resource opts out with `checksum => mtime` | treated as unchanged (exit 0), **with a warning** that a file from this source can never be detected as changed | rewrite + notify fires every run (exit 2), no warning |

Scenario 2 is the exact shape of `puppetlabs/puppet#9553`, verified against
headers matching the real `https://packages.adoptium.net/artifactory/...`
URL from that issue (neither `ETag` nor `Last-Modified`). Scenario 4 is the
same bug from a different, arguably more common, angle: `raw.githubusercontent.com`
*does* send an `ETag`, but `#collect` only ever consults it when the
resource explicitly requests `checksum => etag` — a default `file` resource
against GitHub hits the same bug as Artifactory, just via a different path
through the fallback chain. Scenario 5 is included so the fix doesn't
overclaim — a server whose `Last-Modified` itself lies is a different,
still-open problem, not something this change touches. Scenario 7 guards
the failure-propagation property of the fix: the fix's verification GET
must not swallow a failure and report a clean run — both branches must
fail loudly here, just via different code paths. Scenario 8 covers the
explicit `mtime`/`ctime` opt-out: with no time header from the server there
is nothing to compare against, so the fix treats the file as unchanged
forever — a silent-staleness trade-off the fix deliberately announces with
a warning on every run rather than degrading quietly (an explicit
`checksum => none` stays quiet, since "don't verify" is exactly what was
asked for).

The script checks for `Triggered 'refresh'` in the `puppet apply` output as
the signal that `notify` fired (the `exec`'s own `NOTIFY_FIRED` stdout isn't
logged by Puppet without `logoutput => true`, so don't key off that if you
adapt this).

## Why Docker instead of Vagrant

This only exercises agent-side `file` resource / HTTP client behavior — no
puppetserver, no catalog compiler, no second node. `puppet apply` running
directly from the checked-out gem is the entire test subject, so a single
lightweight Linux container is enough; a full VM would only add boot time
for no benefit here.
