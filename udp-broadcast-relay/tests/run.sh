#!/bin/sh
# Off-box tests for udp-broadcast-relay. Needs: sh, coreutils. Stubs systemctl
# shellcheck disable=SC2016 # sh -c scripts are single-quoted on purpose
# and ip. Runs on a fixture root (UBR_ROOT), so it touches no real path.
# Usage: tests/run.sh      (UBR_SCRIPT overrides the script under test)
# No set -e, so that a failing command under test does not stop the suite.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${UBR_SCRIPT:-$HERE/../udp-broadcast-relay}"
ARCH=$(uname -m)
PASS=0
FAIL=0
TOP=$(mktemp -d) || { echo "cannot create a temp dir; aborting" >&2; exit 1; }
case "$TOP" in /?*/?*) ;; *) echo "unsafe temp dir '$TOP'; aborting" >&2; exit 1 ;; esac
trap 'rm -rf -- "${TOP:?}"' EXIT
ORIG_PATH=$PATH

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
# check LABEL CMD...: pass when the command succeeds.
check() { l=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$l"; fi; }
# refuse LABEL CMD...: pass when the command fails.
refuse() { l=$1; shift; if "$@" >/dev/null 2>&1; then bad "$l"; else ok; fi; }
has() { grep -q -- "$2" "$1" 2>/dev/null; }

# ---------- fixture ----------

# iface NAME FLAGS CIDR: a fake interface.
iface() {
    mkdir -p "$R/sys/class/net/$1"
    printf '%s\n' "$2" >"$R/sys/class/net/$1/flags"
    printf '7: %s    inet %s scope global %s\\       valid_lft forever\n' "$1" "$3" "$1" >"$S/ip-$1"
}

conf() { # NAME CONTENT
    mkdir -p "$R/data/unifi-common-addons/udp-broadcast-relay/instances/$1"
    printf '%s\n' "$2" >"$R/data/unifi-common-addons/udp-broadcast-relay/instances/$1/relay.conf"
}
GOOD='ID=1
PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.255'

setup() {
    T="$TOP/$1"
    R="$T/root"
    S="$T/state"
    B="$T/bin"
    H="$R/data/unifi-common-addons/udp-broadcast-relay"
    mkdir -p "$R/data/on_boot.d" "$R/etc/systemd/system" "$S" "$B" "$H/bin/$ARCH" "$H/systemd" "$H/on_boot.d"
    cp "$HERE/../systemd/udp-broadcast-relay@.service" "$H/systemd/"
    cp "$HERE/../on_boot.d/20-udp-broadcast-relay.sh" "$H/on_boot.d/"
    cp "$SCRIPT" "$H/udp-broadcast-relay"
    # Fake relay: no arguments gives usage and exit 1, like the real one.
    cat >"$H/bin/$ARCH/udp-broadcast-relay-redux" <<'FAKE'
#!/bin/sh
[ $# -gt 0 ] || exit 1
printf '%s\n' "$@" >"$(dirname "$0")/args"
FAKE
    chmod 755 "$H/bin/$ARCH/udp-broadcast-relay-redux" "$H/udp-broadcast-relay"
    rehash
    cat >"$B/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_STATE/systemctl.log"
[ ! -e "$STUB_STATE/fail-$1" ] || exit 1
case "$1" in is-active)
    [ ! -e "$STUB_STATE/inactive" ] || { echo inactive; exit 3; }
    echo active ;;
esac
exit 0
STUB
    cat >"$B/ip" <<'STUB'
#!/bin/sh
# ip -4 -o addr show dev NAME
cat "$STUB_STATE/ip-$6" 2>/dev/null || exit 1
STUB
    chmod 755 "$B/systemctl" "$B/ip"
    iface br0 0x1003 192.168.1.1/24
    iface br30 0x1003 192.168.30.1/24
    export UBR_ROOT="$R" STUB_STATE="$S"
    PATH="$B:$ORIG_PATH"
    export PATH
}

# rehash: list the fixture binary's hash in SHA256SUMS, as install would.
rehash() {
    (cd "$H/bin" && sha256sum "$ARCH/udp-broadcast-relay-redux") >"$H/SHA256SUMS"
}

# ubr ARGS...: run the script under test from the fixture's own home.
ubr() { "$H/udp-broadcast-relay" "$@"; }

# ---------- precheck: config ----------

setup good
conf hdhr "$GOOD"
check "precheck passes on the good config" ubr precheck hdhr

setup missing-id
conf hdhr 'PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.255'
refuse "missing ID" ubr precheck hdhr

setup missing-port
conf hdhr 'ID=1
DEVS="br0 br30"
TARGET=192.168.30.255'
refuse "missing PORT" ubr precheck hdhr

setup missing-devs
conf hdhr 'ID=1
PORT=65001
TARGET=192.168.30.255'
refuse "missing DEVS" ubr precheck hdhr

setup missing-target
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br30"'
refuse "missing TARGET" ubr precheck hdhr

setup no-config
refuse "no relay.conf" ubr precheck hdhr

for id in 0 100 abc 01 ''; do
    setup "id-$id"
    conf hdhr "ID=$id
PORT=65001
DEVS=\"br0 br30\"
TARGET=192.168.30.255"
    refuse "ID '$id' out of range or not a number" ubr precheck hdhr
done

for port in abc 0 65536 6x5 ''; do
    setup "port-$port"
    conf hdhr "ID=1
PORT=$port
DEVS=\"br0 br30\"
TARGET=192.168.30.255"
    refuse "PORT '$port' is not a valid port" ubr precheck hdhr
done

setup one-iface
conf hdhr 'ID=1
PORT=65001
DEVS="br0"
TARGET=192.168.1.255'
refuse "one interface only" ubr precheck hdhr

setup dup-iface
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br0"
TARGET=192.168.1.255'
refuse "the same interface twice" ubr precheck hdhr

setup unknown-key
conf hdhr "$GOOD
EXTRA=1"
refuse "unknown key" ubr precheck hdhr

setup code-in-conf
conf hdhr "ID=1
PORT=65001
DEVS=\"br0 br30 \$(touch $T/pwned)\"
TARGET=192.168.30.255"
ubr precheck hdhr >/dev/null 2>&1
check "the config is data and never runs as shell" test ! -e "$T/pwned"

# ---------- precheck: gateway state ----------

setup no-iface
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br9"
TARGET=192.168.1.255'
refuse "named interface does not exist" ubr precheck hdhr

setup down-iface
conf hdhr "$GOOD"
iface br30 0x1002 192.168.30.1/24
refuse "interface is down" ubr precheck hdhr

setup no-ipv4
conf hdhr "$GOOD"
: >"$S/ip-br0"
refuse "interface without an IPv4 address" ubr precheck hdhr

setup wrong-target
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br30"
TARGET=192.168.40.255'
refuse "TARGET on no listed network" ubr precheck hdhr

setup target-not-bcast
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.100'
refuse "TARGET is a host address, not the broadcast address" ubr precheck hdhr

setup target-limited
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br30"
TARGET=255.255.255.255'
refuse "TARGET 255.255.255.255 is not a network broadcast address" ubr precheck hdhr

setup target-mask
conf hdhr "$GOOD"
iface br30 0x1003 192.168.30.1/25
refuse "TARGET does not match a /25 network (broadcast .127)" ubr precheck hdhr
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.127'
check "TARGET matches the /25 broadcast address" ubr precheck hdhr

setup port-clash
conf hdhr "$GOOD"
conf other 'ID=2
PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.255'
: >"$H/instances/other/active"
refuse "second enabled instance on the same PORT" ubr precheck hdhr

setup port-other
conf hdhr "$GOOD"
conf other 'ID=2
PORT=65002
DEVS="br0 br30"
TARGET=192.168.30.255'
: >"$H/instances/other/active"
check "an enabled instance on another PORT is fine" ubr precheck hdhr

setup port-inactive
conf hdhr "$GOOD"
conf other 'ID=2
PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.255'
check "a disabled instance on the same PORT is fine" ubr precheck hdhr

# other was started on 65001, then its config was changed to 65002.
setup port-running
conf hdhr "$GOOD"
conf other 'ID=2
PORT=65002
DEVS="br0 br30"
TARGET=192.168.30.255'
: >"$H/instances/other/active"
mkdir -p "$R/run/udp-broadcast-relay"
echo 65001 >"$R/run/udp-broadcast-relay/other.port"
refuse "a running instance on the same PORT, config changed since its start" ubr precheck hdhr
: >"$S/inactive"
check "the port record of a stopped instance is ignored" ubr precheck hdhr

setup run-port
conf hdhr "$GOOD"
ubr run hdhr >/dev/null 2>&1
check "run records the port of the relay it starts" \
    test "$(cat "$R/run/udp-broadcast-relay/hdhr.port" 2>/dev/null)" = 65001

setup id-64
conf hdhr 'ID=64
PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.255'
refuse "ID 64 (copies get TTL 128, the Windows default)" ubr precheck hdhr

# A symlink above the instance directory could point into another addon.
setup symlink-inst
conf hdhr "$GOOD"
OTHER="$T/other-addon/instances"
mkdir -p "$OTHER/hdhr"
: >"$OTHER/hdhr/active"
rm -rf "${H:?}/instances"
ln -s "$OTHER" "$H/instances"
refuse "disable with a symlinked instances directory" ubr disable hdhr
check "disable did not delete through the instances symlink" test -e "$OTHER/hdhr/active"

setup symlink-home
conf hdhr "$GOOD"
: >"$H/instances/hdhr/active"
mv "$H" "$T/real-home"
ln -s "$T/real-home" "$H"
refuse "disable with a symlinked addon home" "$T/real-home/udp-broadcast-relay" disable hdhr

setup no-binary
conf hdhr "$GOOD"
rm -f "$H/bin/$ARCH/udp-broadcast-relay-redux"
refuse "binary missing" ubr precheck hdhr

setup bad-binary
conf hdhr "$GOOD"
printf '#!/bin/sh\nexit 126\n' >"$H/bin/$ARCH/udp-broadcast-relay-redux"
rehash
refuse "binary that does not run" ubr precheck hdhr

setup bad-hash
conf hdhr "$GOOD"
echo '# changed' >>"$H/bin/$ARCH/udp-broadcast-relay-redux"
refuse "binary hash does not match" ubr precheck hdhr
check "status reports a hash mismatch" sh -c '"$1" status | grep -q "HASH DOES NOT MATCH"' sh "$H/udp-broadcast-relay"

setup hash-before-run
conf hdhr "$GOOD"
printf '#!/bin/sh\n: >"$STUB_STATE/ran"\nexit 1\n' >"$H/bin/$ARCH/udp-broadcast-relay-redux"
ubr precheck hdhr >/dev/null 2>&1
check "precheck never runs a binary with a wrong hash" test ! -e "$S/ran"

setup hash-other-arch
conf hdhr "$GOOD"
sed -i "s|  $ARCH/|  other-cpu/|" "$H/SHA256SUMS"
refuse "a hash listed for another CPU is not accepted" ubr precheck hdhr

setup no-sums
conf hdhr "$GOOD"
rm -f "$H/SHA256SUMS"
refuse "no SHA256SUMS" ubr precheck hdhr

check "the committed SHA256SUMS lists aarch64 and x86_64" sh -c \
    'grep -Eq "^[0-9a-f]{64}  aarch64/udp-broadcast-relay-redux$" "$1" && grep -Eq "^[0-9a-f]{64}  x86_64/udp-broadcast-relay-redux$" "$1"' \
    sh "$HERE/../SHA256SUMS"

setup bad-name
conf hdhr "$GOOD"
mkdir -p "$H/x"
printf '%s\n' "$GOOD" >"$H/x/relay.conf"
refuse "instance name with a slash" ubr precheck ../x

# precheck and status change nothing
setup readonly
conf hdhr "$GOOD"
before=$(cd "$R" && find . -type f -exec sha256sum {} + | sort | sha256sum)
ubr precheck hdhr >/dev/null 2>&1
ubr status >/dev/null 2>&1
after=$(cd "$R" && find . -type f -exec sha256sum {} + | sort | sha256sum)
check "precheck and status change no file" test "$before" = "$after"
refuse "precheck and status never call systemctl to change state" grep -Eq '^(start|stop|restart|enable|disable|daemon-reload)' "$S/systemctl.log"

setup loopback
conf hdhr 'ID=1
PORT=65001
DEVS="lo br30"
TARGET=192.168.30.255'
iface lo 0x9 127.0.0.1/8
refuse "loopback interface in DEVS" ubr precheck hdhr

setup multi-addr
conf hdhr "$GOOD"
printf '7: br30    inet 192.168.30.1/24 scope global br30\\       valid_lft forever\n7: br30    inet 192.168.40.1/24 scope global br30\\       valid_lft forever\n' >"$S/ip-br30"
check "TARGET on the first of two addresses of one interface" ubr precheck hdhr
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br30"
TARGET=192.168.40.255'
check "TARGET on the second of two addresses of one interface" ubr precheck hdhr

setup compound-target
conf hdhr 'ID=1
PORT=65001
DEVS="br0 br30"
TARGET="192.168.1.255 192.168.30.255"'
refuse "two addresses in TARGET" ubr precheck hdhr

setup symlink-instance
conf real "$GOOD"
ln -s real "$H/instances/hdhr"
refuse "instance directory is a symlink (precheck)" ubr precheck hdhr
refuse "instance directory is a symlink (disable)" ubr disable hdhr

setup symlink-active
conf hdhr "$GOOD"
mkdir -p "$T/victim"
echo keep >"$T/victim/file"
ln -s "$T/victim/file" "$H/instances/hdhr/active"
refuse "enable with an active symlink" ubr enable hdhr
check "enable did not write through the symlink" has "$T/victim/file" '^keep$'
refuse "disable with an active symlink" ubr disable hdhr
check "disable did not delete the symlink target" test -f "$T/victim/file"

setup run-recheck
conf hdhr "$GOOD"
conf other 'ID=2
PORT=65001
DEVS="br0 br30"
TARGET=192.168.30.255'
: >"$H/instances/other/active"
refuse "run checks the port conflict again" ubr run hdhr

# ---------- run ----------

setup run
conf hdhr "$GOOD"
ubr run hdhr >/dev/null 2>&1
printf '%s\n' --id 1 --port 65001 -t 192.168.30.255 --dev br0 --dev br30 >"$T/want-args"
check "run passes -t, the id, the port, and each device" cmp "$H/bin/$ARCH/args" "$T/want-args"

# ---------- enable, disable, boot ----------

setup enable
conf hdhr "$GOOD"
ubr enable hdhr >/dev/null 2>&1
check "enable marks the instance active" test -f "$H/instances/hdhr/active"
check "enable starts the unit" has "$S/systemctl.log" '^restart udp-broadcast-relay@hdhr.service$'

setup enable-bad
conf hdhr 'ID=1
PORT=65001
DEVS="br0"
TARGET=192.168.30.255'
refuse "enable fails on a bad config" ubr enable hdhr
check "a failed enable leaves no active mark" test ! -e "$H/instances/hdhr/active"

setup disable
conf hdhr "$GOOD"
ubr enable hdhr >/dev/null 2>&1
ubr disable hdhr >/dev/null 2>&1
check "disable removes active" test ! -e "$H/instances/hdhr/active"
check "disable keeps the config" test -f "$H/instances/hdhr/relay.conf"
check "disable stops the unit" has "$S/systemctl.log" '^stop udp-broadcast-relay@hdhr.service$'

setup disable-stopfail
conf hdhr "$GOOD"
ubr enable hdhr >/dev/null 2>&1
: >"$S/fail-stop"
refuse "disable fails when the stop fails" ubr disable hdhr
check "a failed stop keeps the active mark" test -f "$H/instances/hdhr/active"
refuse "uninstall fails when a stop fails" ubr uninstall
check "a failed stop keeps the addon directory" test -d "$H"

snapshot() { (cd "$R" && find . -type f ! -name '*.log' -exec sha256sum {} + | sort; find . | sort); }
setup boot
conf hdhr "$GOOD"
ubr enable hdhr >/dev/null 2>&1
ubr boot >/dev/null 2>&1
check "boot installs the unit" test -f "$R/etc/systemd/system/udp-broadcast-relay@.service"
check "boot starts an active instance" has "$S/systemctl.log" '^start --no-block udp-broadcast-relay@hdhr.service$'
snapshot >"$T/snap1"
ubr boot >/dev/null 2>&1
snapshot >"$T/snap2"
check "boot twice gives the same files" cmp "$T/snap1" "$T/snap2"
rm -f "$R/etc/systemd/system/udp-broadcast-relay@.service"
ubr boot >/dev/null 2>&1
check "boot restores a unit that a firmware update removed" test -f "$R/etc/systemd/system/udp-broadcast-relay@.service"

setup boot-inactive
conf hdhr "$GOOD"
ubr boot >/dev/null 2>&1
refuse "boot starts no instance that is not active" has "$S/systemctl.log" '^start .*hdhr'

# ---------- lock and arguments ----------

# locked ARGS...: run the script while another process holds the lock, with
# no wait. Sets rc to its exit status.
locked() {
    mkdir -p "$R/run"
    flock "$R/run/udp-broadcast-relay.lock" sleep 5 &
    holder=$!
    sleep 1
    UBR_LOCK_WAIT=0 ubr "$@" >/dev/null 2>&1
    rc=$?
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
}

setup lock-boot
conf hdhr "$GOOD"
locked boot
check "boot fails when another command holds the lock" test "$rc" -ne 0
check "boot writes nothing while another command holds the lock" test ! -e "$R/etc/systemd/system/udp-broadcast-relay@.service"

setup lock-install
conf hdhr "$GOOD"
locked install
check "install fails and writes nothing while another command holds the lock" \
    test "$rc" -ne 0 -a ! -e "$R/etc/systemd/system/udp-broadcast-relay@.service"

setup lock-enable
conf hdhr "$GOOD"
locked enable hdhr
check "enable fails and marks nothing while another command holds the lock" \
    test "$rc" -ne 0 -a ! -e "$H/instances/hdhr/active"

setup lock-disable
conf hdhr "$GOOD"
: >"$H/instances/hdhr/active"
locked disable hdhr
check "disable fails and keeps the mark while another command holds the lock" \
    test "$rc" -ne 0 -a -e "$H/instances/hdhr/active"

setup lock-uninstall
conf hdhr "$GOOD"
locked uninstall
check "uninstall fails and removes nothing while another command holds the lock" \
    test "$rc" -ne 0 -a -d "$H"

setup lock-free
conf hdhr "$GOOD"
check "boot runs when no other command holds the lock" ubr boot

setup args
conf hdhr "$GOOD"
refuse "status rejects an extra argument" ubr status hdhr
refuse "boot rejects an extra argument" ubr boot hdhr
refuse "enable rejects two names" ubr enable hdhr other
check "the unit waits for /data" grep -q '^RequiresMountsFor=/data$' "$HERE/../systemd/udp-broadcast-relay@.service"
check "the unit runs precheck before the relay" grep -qx 'ExecStartPre=/data/unifi-common-addons/udp-broadcast-relay/udp-broadcast-relay precheck %i' "$HERE/../systemd/udp-broadcast-relay@.service"
check "the unit starts the relay with run" grep -qx 'ExecStart=/data/unifi-common-addons/udp-broadcast-relay/udp-broadcast-relay run %i' "$HERE/../systemd/udp-broadcast-relay@.service"

# ---------- install and uninstall ----------

setup install
SRC="$T/src"
mkdir -p "$SRC/systemd" "$SRC/on_boot.d" "$SRC/instances/hdhr" "$SRC/bin/$ARCH"
cp "$SCRIPT" "$SRC/udp-broadcast-relay"
cp "$HERE/../systemd/"*.service "$SRC/systemd/"
cp "$HERE/../on_boot.d/"*.sh "$SRC/on_boot.d/"
cp "$HERE/../instances/hdhr/relay.conf.example" "$SRC/instances/hdhr/"
cp "$H/bin/$ARCH/udp-broadcast-relay-redux" "$SRC/bin/$ARCH/"
cp "$H/SHA256SUMS" "$SRC/"
rm -rf "${H:?}"
"$SRC/udp-broadcast-relay" install >/dev/null 2>&1
check "install copies the script" test -x "$H/udp-broadcast-relay"
check "install copies the binary" test -x "$H/bin/$ARCH/udp-broadcast-relay-redux"
check "install copies SHA256SUMS" cmp "$SRC/SHA256SUMS" "$H/SHA256SUMS"
check "install writes the boot entry" test -x "$R/data/on_boot.d/20-udp-broadcast-relay.sh"
check "install writes the unit" test -f "$R/etc/systemd/system/udp-broadcast-relay@.service"
refuse "install starts nothing" grep -Eq "^(start|restart)" "$S/systemctl.log"
conf hdhr "# mine
$GOOD"
"$SRC/udp-broadcast-relay" install >/dev/null 2>&1
check "install keeps an existing relay.conf" has "$H/instances/hdhr/relay.conf" '^# mine$'
out=$("$SRC/udp-broadcast-relay" install 2>&1)
refuse "install gives no warning for a complete copy" sh -c 'printf "%s" "$1" | grep -q WARNING' sh "$out"

setup install-incomplete
SRC="$T/src"
mkdir -p "$SRC/systemd" "$SRC/on_boot.d"
cp "$SCRIPT" "$SRC/udp-broadcast-relay"
cp "$HERE/../systemd/"*.service "$SRC/systemd/"
cp "$HERE/../on_boot.d/"*.sh "$SRC/on_boot.d/"
rm -rf "${H:?}"
out=$("$SRC/udp-broadcast-relay" install 2>&1)
check "install warns when the copy has no SHA256SUMS" sh -c 'printf "%s" "$1" | grep -q "WARNING: no .*SHA256SUMS"' sh "$out"
check "install warns when the copy has no binary for this CPU" sh -c 'printf "%s" "$1" | grep -q "WARNING: no binary"' sh "$out"

# incomplete_src PART: a copy of the addon without PART. install must
# refuse it before it writes anything.
for part in systemd/udp-broadcast-relay@.service on_boot.d/20-udp-broadcast-relay.sh; do
    setup "install-no-${part%%/*}"
    SRC="$T/src"
    mkdir -p "$SRC/systemd" "$SRC/on_boot.d"
    cp "$SCRIPT" "$SRC/udp-broadcast-relay"
    cp "$HERE/../systemd/"*.service "$SRC/systemd/"
    cp "$HERE/../on_boot.d/"*.sh "$SRC/on_boot.d/"
    cp "$H/SHA256SUMS" "$SRC/" 2>/dev/null
    rm -f "$SRC/$part"
    rm -rf "${H:?}"
    out=$("$SRC/udp-broadcast-relay" install 2>&1)
    refuse "install fails when the copy has no $part" "$SRC/udp-broadcast-relay" install
    check "install without $part says that nothing changed" sh -c 'printf "%s" "$1" | grep -q "missing .*Nothing changed"' sh "$out"
    check "install without $part writes no addon home" test ! -e "$H"
    check "install without $part writes no boot entry" test ! -e "$R/data/on_boot.d/20-udp-broadcast-relay.sh"
done

# A power loss during put() leaves a temporary copy. boot and install
# remove this addon's copies, and only those.
for c in boot install; do
    setup "stale-tmp-$c"
    conf hdhr "$GOOD"
    : >"$R/data/on_boot.d/20-udp-broadcast-relay.sh.new.4242"
    : >"$R/etc/systemd/system/udp-broadcast-relay@.service.new.4242"
    : >"$H/udp-broadcast-relay.new.4242"
    : >"$R/data/on_boot.d/01-att-wpa-supplicant.sh.new.4242"
    : >"$R/etc/systemd/system/att-wpa-supplicant@.service.new.4242"
    : >"$H/udp-broadcast-relay.new.1-backup"
    : >"$H/instances/hdhr/relay.conf.new.4242"
    ubr "$c" >/dev/null 2>&1
    check "$c removes a stale temporary boot entry" test ! -e "$R/data/on_boot.d/20-udp-broadcast-relay.sh.new.4242"
    check "$c removes a stale temporary unit" test ! -e "$R/etc/systemd/system/udp-broadcast-relay@.service.new.4242"
    check "$c removes a stale temporary file in the home" test ! -e "$H/udp-broadcast-relay.new.4242"
    check "$c keeps another addon's temporary boot entry" test -e "$R/data/on_boot.d/01-att-wpa-supplicant.sh.new.4242"
    check "$c keeps another addon's temporary unit" test -e "$R/etc/systemd/system/att-wpa-supplicant@.service.new.4242"
    check "$c keeps a file whose suffix is not a process ID" test -e "$H/udp-broadcast-relay.new.1-backup"
    check "$c keeps a file that install never writes" test -e "$H/instances/hdhr/relay.conf.new.4242"
done

setup uninstall
conf hdhr "$GOOD"
ubr install >/dev/null 2>&1
ubr enable hdhr >/dev/null 2>&1
ubr uninstall >/dev/null 2>&1
check "uninstall removes the addon directory" test ! -e "$H"
check "uninstall removes the unit" test ! -e "$R/etc/systemd/system/udp-broadcast-relay@.service"
check "uninstall removes the boot entry" test ! -e "$R/data/on_boot.d/20-udp-broadcast-relay.sh"
check "uninstall stops the instance" has "$S/systemctl.log" '^stop udp-broadcast-relay@hdhr.service$'

setup uninstall-renamed
conf hdhr "$GOOD"
ubr install >/dev/null 2>&1
ubr enable hdhr >/dev/null 2>&1
ubr run hdhr >/dev/null 2>&1
mv "$H/instances/hdhr" "$H/instances/saved"
ubr uninstall >/dev/null 2>&1
check "uninstall stops a running relay whose instance directory was renamed" \
    has "$S/systemctl.log" '^stop udp-broadcast-relay@hdhr.service$'
check "uninstall removes the port records" test ! -e "$R/run/udp-broadcast-relay"

# Make the copy of the unit fail. A stub cp fails for that file only, so
# this works as root too (root ignores a read-only mode).
setup write-fail
conf hdhr "$GOOD"
cat >"$B/cp" <<STUB
#!/bin/sh
case "\$*" in *@.service.new.*) : >"\$2"; exit 1 ;; esac
PATH='$ORIG_PATH' exec cp "\$@"
STUB
chmod 755 "$B/cp"
refuse "boot fails when the unit cannot be written" ubr boot
check "boot leaves no temporary unit after a failed copy" sh -c '! ls "$1"/udp-broadcast-relay@.service.new.* >/dev/null 2>&1' sh "$R/etc/systemd/system"

# A file in place of the unit directory: the directory cannot be made.
setup write-fail-dir
conf hdhr "$GOOD"
rm -rf "$R/etc/systemd/system"
: >"$R/etc/systemd/system"
refuse "boot fails when the unit directory cannot be made" ubr boot

# ---------- isolation from att-wpa-supplicant ----------

setup isolation
ATT="$R/data/unifi-common-addons/att-wpa-supplicant"
mkdir -p "$ATT/instances/eth8"
echo sentinel >"$ATT/att-wpa-supplicant"
echo sentinel >"$ATT/instances/eth8/active"
echo sentinel >"$R/data/on_boot.d/01-att-wpa-supplicant.sh"
echo sentinel >"$R/etc/systemd/system/att-wpa-supplicant@.service"
att_state() {
    (cd "$R" && find . -path '*att-wpa-supplicant*' -exec sh -c 'for f; do if [ -f "$f" ]; then sha256sum "$f"; else echo "$f"; fi; done' sh {} + | sort)
}
a1=$(att_state)
conf hdhr "$GOOD"
ubr install >/dev/null 2>&1
ubr enable hdhr >/dev/null 2>&1
ubr boot >/dev/null 2>&1
ubr status >/dev/null 2>&1
ubr disable hdhr >/dev/null 2>&1
ubr uninstall >/dev/null 2>&1
a2=$(att_state)
check "no att-wpa-supplicant file changed or disappeared" test "$a1" = "$a2"
check "the att-wpa-supplicant data directory still exists" test -f "$ATT/instances/eth8/active"
refuse "no systemctl call names att-wpa-supplicant" has "$S/systemctl.log" 'att-wpa'
refuse "the script reaches no path outside its own directories" grep -q '/\.\.' "$SCRIPT"
refuse "the script and unit never name att-wpa-supplicant" grep -rIl att-wpa "$SCRIPT" "$HERE/../systemd" "$HERE/../on_boot.d" "$HERE/../instances"
# Reads: with the att directories unreadable, every command still works.
setup isolation-read
ATT="$R/data/unifi-common-addons/att-wpa-supplicant"
mkdir -p "$ATT"
echo sentinel >"$ATT/att-wpa-supplicant"
chmod 000 "$ATT/att-wpa-supplicant" "$ATT"
conf hdhr "$GOOD"
check "install, enable, status, disable work with att-wpa-supplicant unreadable" \
    sh -c '"$1" install && "$1" enable hdhr && "$1" status && "$1" disable hdhr' sh "$H/udp-broadcast-relay"
chmod 755 "$ATT"

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
