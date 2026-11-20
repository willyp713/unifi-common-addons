#!/bin/sh
# Functional test of udp-broadcast-relay-redux in a private network
# namespace. Needs no sudo: it re-runs itself under `unshare -rn`.
#
# Usage: relay-netns.sh [path-to-binary]
# Env:   RELAY_PORT    port passed to the relay (default 65001). A wrong value
#                      makes the test fail; that is the deliberate-break check.
#        RELAY_TARGET  -t value for phase C (default 10.99.3.255). Set it to
#                      an empty value to omit -t: phase C must then fail.
set -eu

if [ "${NETNS_INNER:-}" != 1 ]; then
    here=$(cd "$(dirname "$0")" && pwd)
    bin=${1:-$here/../dist/$(uname -m)/udp-broadcast-relay-redux}
    [ -x "$bin" ] || { echo "no binary at $bin" >&2; exit 2; }
    NETNS_INNER=1 exec unshare -rn "$0" "$bin"
fi

bin=$1
port=${RELAY_PORT:-65001}
target=${RELAY_TARGET-10.99.3.255}
tmp=$(mktemp -d)
relay_pid=
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap (0.10 and 0.11 codes)
cleanup() {
    if [ -n "$relay_pid" ]; then kill "$relay_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT

command -v python3 >/dev/null || { echo "python3 needed" >&2; exit 2; }

ip link set lo up
for n in 1 3; do
    ip link add br$n type bridge
    ip link add v${n}a type veth peer name v${n}b
    ip link set v${n}a master br$n
    ip addr add 10.99.$n.1/24 broadcast 10.99.$n.255 dev br$n
    ip link set br$n up; ip link set v${n}a up; ip link set v${n}b up
done
ip addr add 10.99.1.50/24 dev br1   # the "app" address on VLAN 01 side
ip addr add 10.99.3.50/24 dev br3   # a second sender on the VLAN 03 side

"$bin" -d --id 1 --port "$port" --dev br1 --dev br3 >"$tmp/relay.log" 2>&1 &
relay_pid=$!
sleep 1
kill -0 "$relay_pid" 2>/dev/null || { echo "FAIL: relay exited"; cat "$tmp/relay.log"; exit 1; }

# Capture UDP 65001 on the far side of each bridge's veth, count packets
# with source address and port. Python raw socket, no tcpdump needed.
cat >"$tmp/cap.py" <<'PY'
import socket, struct, sys, time
iface, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
s.bind((iface, 0)); s.settimeout(0.2)
end = time.time() + secs; rows = []
while time.time() < end:
    try: p = s.recv(4096)
    except socket.timeout: continue
    if p[12:14] != b"\x08\x00" or p[23] != 17: continue
    ihl = (p[14] & 15) * 4
    sp, dp = struct.unpack("!HH", p[14+ihl:18+ihl])
    if dp != 65001: continue
    rows.append("%s %d %s" % (socket.inet_ntoa(p[26:30]), sp, socket.inet_ntoa(p[30:34])))
open(out, "w").write("\n".join(rows) + ("\n" if rows else ""))
PY
cat >"$tmp/send.py" <<'PY'
import socket, sys
src, sport = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.bind((src, sport))
s.sendto(b"HDHR-DISCOVER", ("255.255.255.255", 65001))
PY

# Phase A: broadcast from br1 side. Capture on v3b (far end of br3) and v1b.
python3 "$tmp/cap.py" v3b 3 "$tmp/a3" & c1=$!
python3 "$tmp/cap.py" v1b 3 "$tmp/a1" & c2=$!
sleep 0.5
python3 "$tmp/send.py" 10.99.1.50 45678
wait $c1 $c2

fail=0
# br3-side copy: original source address and port, exactly once.
want="10.99.1.50 45678 10.99.3.255"
n=$(grep -cx "$want" "$tmp/a3" || true)
if [ "$n" -eq 1 ]; then echo "PASS A1: copy on br3 keeps source 10.99.1.50:45678"
else echo "FAIL A1: expected one '$want' on br3, got $n"; head -5 "$tmp/a3"; fail=1; fi
# No echo back on the originating side beyond the original packet.
n=$(wc -l <"$tmp/a1")
if [ "$n" -eq 1 ]; then echo "PASS A2: br1 saw only the original packet (no loop)"
else echo "FAIL A2: br1 saw $n packets, expected 1"; head -5 "$tmp/a1"; fail=1; fi

# Phase B: broadcast from br3 side; each side must see exactly one copy.
python3 "$tmp/cap.py" v3b 3 "$tmp/b3" & c1=$!
python3 "$tmp/cap.py" v1b 3 "$tmp/b1" & c2=$!
sleep 0.5
python3 "$tmp/send.py" 10.99.3.50 45679
wait $c1 $c2
n1=$(grep -cx "10.99.3.50 45679 10.99.1.255" "$tmp/b1" || true)
n3=$(wc -l <"$tmp/b3")
t1=$(wc -l <"$tmp/b1")
if [ "$n1" -eq 1 ] && [ "$t1" -eq 1 ] && [ "$n3" -eq 1 ]; then
    echo "PASS B: reverse direction relays once with original source, no loop"
else echo "FAIL B: br1 matching=$n1 total=$t1, br3 total=$n3"; fail=1; fi

# Phase C: as on UniFi OS, the bridges have no broadcast address, so the
# relay needs -t. Re-add each address without one and restart the relay.
kill "$relay_pid" 2>/dev/null || true
wait "$relay_pid" 2>/dev/null || true
relay_pid=
for n in 1 3; do
    ip addr flush dev br$n
    ip addr add 10.99.$n.1/24 dev br$n
done
ip addr add 10.99.1.50/24 dev br1
set -- -d --id 1 --port "$port" --dev br1 --dev br3
[ -z "$target" ] || set -- "$@" -t "$target"
"$bin" "$@" >"$tmp/relay-c.log" 2>&1 &
relay_pid=$!
sleep 1
python3 "$tmp/cap.py" v3b 3 "$tmp/c3" & c1=$!
sleep 0.5
python3 "$tmp/send.py" 10.99.1.50 45680
wait $c1
want="10.99.1.50 45680 10.99.3.255"
n=$(grep -cx "$want" "$tmp/c3" || true)
if [ "$n" -eq 1 ]; then echo "PASS C: no broadcast address on the bridges; -t copy on br3 keeps the source"
else echo "FAIL C: expected one '$want' on br3, got $n"; head -5 "$tmp/c3"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
