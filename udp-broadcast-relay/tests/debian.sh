#!/bin/sh
# Run tests/run.sh in Debian 11, 12, and 13 containers, as root. UniFi OS
# 4.x and later is built on these releases, so the script must work with
# their versions of sh, flock, sed, and coreutils. Also run the host binary
# from dist/ (static), which must print its usage and exit 1.
# Needs docker. Usage: tests/debian.sh      Exit 0 only when all pass.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
fail=0
for r in bullseye bookworm trixie; do
    out=$(docker run --rm -v "$HERE:/a:ro" "debian:$r-slim" sh -c '
        sh /a/tests/run.sh >/tmp/out 2>&1; rc=$?
        tail -n 1 /tmp/out
        [ "$rc" -eq 0 ] || { grep "^FAIL" /tmp/out; exit 1; }
        bin=/a/dist/$(uname -m)/udp-broadcast-relay-redux
        [ -x "$bin" ] || { echo "no $bin (run tools/build.sh)"; exit 1; }
        brc=0; "$bin" >/dev/null 2>&1 || brc=$?
        [ "$brc" -eq 1 ] || { echo "binary exit $brc, not 1"; exit 1; }
        echo "binary runs"') || fail=1
    echo "$r: $(printf '%s' "$out" | tr '\n' ' ')"
done
[ "$fail" -eq 0 ]
