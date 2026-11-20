#!/bin/sh
# shellcheck disable=SC2016 # the sed scripts are single-quoted on purpose
# Mutation check for tests/run.sh. For each deliberate fault in the script,
# run the suite against the faulty copy. The suite must fail, and it must
# name the assertion that this fault should break.
# Usage: tests/mutate.sh      Exit 0 only when every fault is caught.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../udp-broadcast-relay"
TOP=$(mktemp -d) || exit 1
trap 'rm -rf -- "${TOP:?}"' EXIT
total=0
missed=0

# mutant EXPECTED-FAILURE-TEXT SED-SCRIPT...
mutant() {
    want=$1; shift
    total=$((total + 1))
    cp "$SRC" "$TOP/m"
    for e in "$@"; do sed -i "$e" "$TOP/m"; done
    if cmp -s "$SRC" "$TOP/m"; then
        echo "NO-OP   $want (the sed script changed nothing)"; missed=$((missed + 1)); return
    fi
    if out=$(UBR_SCRIPT="$TOP/m" "$HERE/run.sh" 2>&1); then
        echo "MISSED  $want (suite passed on the faulty script)"; missed=$((missed + 1))
    elif printf '%s\n' "$out" | grep -qF -- "FAIL: $want"; then
        echo "caught  $want"
    else
        echo "WRONG   $want (suite failed, but not on this assertion)"
        printf '%s\n' "$out" | grep '^FAIL' | head -3
        missed=$((missed + 1))
    fi
}

mutant "ID '100' out of range" 's~is_count "$ID" 1 99~is_count "$ID" 1 999~'
mutant "ID '01' out of range" 's~''|\*\[!0-9\]\*|0?\*~''|*[!0-9]*~'
mutant "PORT '65536' is not a valid port" 's~is_count "$PORT" 1 65535~is_count "$PORT" 1 99999~'
mutant "one interface only" 's~-ge 2 \]~-ge 1 ]~'
mutant "the same interface twice" 's~\*" \$d "\*) set +f~*" XX "*) set +f~'
mutant "unknown key" 's~unknown key \$key"; return 1~unknown key $key"; true~'
mutant "the config is data and never runs as shell" 's~^    done <"$conf"~    done <"$conf"; . "$conf"~'
mutant "missing ID" 's~is_count "$ID" 1 99 ||~true ||~'
mutant "missing PORT" 's~is_count "$PORT" 1 65535 ||~true ||~'
mutant "missing DEVS" 's~-ge 2 \]~-ge 0 ]~' 's~^    found=0$~    found=1~'
mutant "interface is down" 's~\[ \$((flags & 1)) -eq 1 \]~[ 0 -eq 0 ]~'
mutant "named interface does not exist" 's~\[ -d "$SYSNET/$d" \] ||~true ||~' 's~\[ \$((flags & 1)) -eq 1 \]~[ 0 -eq 0 ]~' 's~\[ -n "$a" \] ||~true ||~'
mutant "TARGET on no listed network" 's~^    found=0$~    found=1~'
mutant "TARGET does not match a /25 network (broadcast .127)" 's~<< (32 - len)~<< 8~'
mutant "second enabled instance on the same PORT" 's~\[ "$oport" = "$PORT" \]~[ "$oport" = x ]~'
mutant "an enabled instance on another PORT is fine" 's~\[ "$oport" = "$PORT" \]~[ -n "$oport" ]~'
mutant "a disabled instance on the same PORT is fine" 's~ \&\& \[ -f "$other/active" \]; }~; }~'
mutant "binary that does not run" 's~\[ "$rc" -eq 1 \] ||~true ||~'
mutant "binary missing" 's~\[ -x "$bin" \] ||~true ||~' 's~\[ "$rc" -eq 1 \] ||~true ||~' 's~^    bin_hash_ok "$bin" || return 1~    :~'
mutant "instance name with a slash" 's~\*\[!A-Za-z0-9_-\]\*) return 1~*[!A-Za-z0-9_./-]*) return 1~'
mutant "precheck and status change no file" 's~^cmd_precheck() {~cmd_precheck() { : >"$INST/touched";~'
mutant "precheck and status never call systemctl to change state" 's~^cmd_precheck() {~cmd_precheck() { systemctl daemon-reload;~'
mutant "run passes -t, the id, the port, and each device" 's~ -t "$TARGET"~~'
mutant "enable marks the instance active" 's~^    : >"$INST/$1/active"~    :~'
mutant "enable starts the unit" 's~systemctl restart "$PROG@$1.service"~:~'
mutant "enable fails on a bad config" 's~cmd_precheck "$1" || die~cmd_precheck "$1" || true~'
mutant "a failed enable leaves no active mark" 's~cmd_precheck "$1" || die~cmd_precheck "$1" || true~'
mutant "disable removes active" 's~rm -f "${INST:?}/$name/active"~:~'
mutant "disable keeps the config" 's~rm -f "${INST:?}/$name/active"~rm -rf "${INST:?}/$name"~'
mutant "disable stops the unit" 's~systemctl stop "$PROG@$name.service" || die "could not stop $name; it stays active"~:~'
mutant "boot installs the unit" 's~if \[ -d "$DATA" \] && install_unit; then reload; fi~:~'
mutant "boot starts an active instance" 's~systemctl start --no-block~:~'
mutant "boot twice gives the same files" 's~^cmd_boot() {~cmd_boot() { date +%s%N >"$DATA/stamp";~'
mutant "boot restores a unit that a firmware update removed" 's~if \[ -d "$DATA" \] && install_unit; then reload; fi~:~'
mutant "boot starts no instance that is not active" 's~\[ -f "$INST/$name/active" \] || continue~:~'
mutant "install copies the script" 's~put 0755 "$self/$PROG" "$DATA/$PROG" || true~:~'
mutant "install copies the binary" 's~put 0755 "$f" "$DATA/bin/${n##\*/}/$BIN_NAME" || true~:~'
mutant "install writes the boot entry" 's~^    install_onboot$~    :~'
mutant "install writes the unit" 's~if install_unit; then reload; fi~:~'
mutant "install starts nothing" 's~^    note "installed\.~    systemctl start x; note "installed.~'
mutant "install keeps an existing relay.conf" 's~/relay.conf.example" || true~/relay.conf" || true~'
mutant "uninstall removes the addon directory" 's~rm -rf "${DATA:?}"~:~'
mutant "uninstall removes the unit" 's~rm -f "${UNITS:?}/$UNIT_NAME" "${ONBOOT:?}/$ONBOOT_NAME"~rm -f "${ONBOOT:?}/$ONBOOT_NAME"~'
mutant "uninstall removes the boot entry" 's~rm -f "${UNITS:?}/$UNIT_NAME" "${ONBOOT:?}/$ONBOOT_NAME"~rm -f "${UNITS:?}/$UNIT_NAME"~'
mutant "uninstall stops the instance" 's~systemctl stop "$PROG@$name.service" || die "could not stop $name; nothing was removed"~:~'
mutant "no att-wpa-supplicant file changed or disappeared" 's~^    rm -rf "${DATA:?}"~    rm -f "$R/data/on_boot.d/01-att-wpa-supplicant.sh"; rm -rf "${DATA:?}"~'
mutant "install, enable, status, disable work with att-wpa-supplicant unreadable" 's~^    echo "home:       $DATA"~    cat "$DATA/../att-wpa-supplicant/att-wpa-supplicant" >/dev/null; echo "home:       $DATA"~'
mutant "the script and unit never name att-wpa-supplicant" 's~^PROG=udp-broadcast-relay~PROG=udp-broadcast-relay # att-wpa-supplicant~'
mutant "no systemctl call names att-wpa-supplicant" 's~^    reload || true~    systemctl stop att-wpa-supplicant@eth8.service; reload || true~'

mutant "loopback interface in DEVS" 's~\[ $((flags & 8)) -eq 0 \] ||~true ||~'
mutant "TARGET on the second of two addresses of one interface" 's~cidr_bcast "$cidr"$~cidr_bcast "$cidr" \&\& break~'
mutant "two addresses in TARGET" 's~case $TARGET in \*\[!0-9.\]\*) err~case $TARGET in XX) err~' 's~\[ "$b" != "$TARGET" \] || found=1~[ "$b" != "${TARGET%% *}" ] || found=1~'
mutant "instance directory is a symlink (precheck)" 's~\[ -d "$INST/$1" \] \&\& \[ ! -L "$INST/$1" \]~[ -d "$INST/$1" ]~'
mutant "enable with an active symlink" 's~\[ ! -L "$INST/$1/active" \] ||~true ||~'
mutant "enable did not write through the symlink" 's~\[ ! -L "$INST/$1/active" \] ||~true ||~'
mutant "run checks the port conflict again" 's~^    cmd_precheck "$@" || exit 1~    parse_conf "$1" || exit 1~'
mutant "run passes -t, the id, the port, and each device" 's~exec "$DATA/bin/$(uname -m)/$BIN_NAME" "$@"~exec "$DATA/bin/$(uname -m)/$BIN_NAME" "$*"~'
mutant "disable fails when the stop fails" 's~|| die "could not stop $name; it stays active"~|| true~'
mutant "a failed stop keeps the active mark" 's~|| die "could not stop $name; it stays active"~|| true~'
mutant "uninstall fails when a stop fails" 's~|| die "could not stop $name; nothing was removed"~|| true~'
mutant "a failed stop keeps the addon directory" 's~|| die "could not stop $name; nothing was removed"~|| true~'
mutant "boot fails when the unit cannot be written" 's~        die "cannot write $3"~        return 0~'
mutant "binary hash does not match" 's~^    bin_hash_ok "$bin" || return 1~    :~'
mutant "precheck never runs a binary with a wrong hash" 's~^    bin_hash_ok "$bin" || return 1~    "$bin" >/dev/null 2>\&1; bin_hash_ok "$bin" || return 1~'
mutant "a hash listed for another CPU is not accepted" 's~  $(uname -m)/$BIN_NAME~  [a-z0-9_-]*/$BIN_NAME~'
mutant "status reports a hash mismatch" 's~h="HASH DOES NOT MATCH SHA256SUMS"~h="hash matches SHA256SUMS"~'
mutant "install copies SHA256SUMS" 's~|| put 0644 "$self/SHA256SUMS" "$SUMS" || true~|| true~'
mutant "boot fails when another command holds the lock" '/^cmd_boot() {/,/^}/s~^    lock$~    :~'
mutant "install fails and writes nothing while another command holds the lock" '/^cmd_install() {/,/^}/s~^    lock$~    :~'
mutant "enable fails and marks nothing while another command holds the lock" '/^cmd_enable() {/,/^}/s~^    lock$~    :~'
mutant "disable fails and keeps the mark while another command holds the lock" '/^cmd_disable() {/,/^}/s~^    lock$~    :~'
mutant "uninstall fails and removes nothing while another command holds the lock" '/^cmd_uninstall() {/,/^}/s~^    lock$~    :~'
mutant "install warns when the copy has no SHA256SUMS" 's~^    \[ -f "$SUMS" \] || note~    true || note~'
mutant "install warns when the copy has no binary for this CPU" 's~^    \[ -f "$DATA/bin/$(uname -m)/$BIN_NAME" \] || note~    true || note~'
mutant "install gives no warning for a complete copy" 's~^    \[ -f "$SUMS" \] || note~    note~'
mutant "boot writes nothing while another command holds the lock" 's~^    flock -w "$LOCK_WAIT" 9 ||.*~    :~'
mutant "status rejects an extra argument" 's~^    no_args status "$@"~    :~'
mutant "boot rejects an extra argument" 's~^    no_args boot "$@"~    :~'
mutant "enable rejects two names" 's~^    \[ $# -eq 1 \] || die "give one~    true || die "give one~'
mutant "the script reaches no path outside its own directories" 's~^BIN_NAME=.*~&\nX=$DATA/../y~'

mutant "interface without an IPv4 address" 's~\[ -n "$a" \] ||~true ||~'
mutant "ID 64 (copies get TTL 128" 's~\[ "$ID" != 64 \] ||~true ||~'
mutant "a running instance on the same PORT, config changed" 's~if systemctl is-active --quiet "$PROG@$oname.service"; then~if false; then~'
mutant "the port record of a stopped instance is ignored" 's~if systemctl is-active --quiet "$PROG@$oname.service"; then~if true; then~'
mutant "run records the port of the relay it starts" 's~>"$RUNDIR/$1.port"; }~>/dev/null; }~'
mutant "disable with a symlinked instances directory" 's~^    \[ ! -L "$INST" \] ||~    true ||~'
mutant "disable did not delete through the instances symlink" 's~^    \[ ! -L "$INST" \] ||~    true ||~'
mutant "disable with a symlinked addon home" 's~^    \[ ! -L "$DATA" \] ||~    true ||~'
mutant "uninstall stops a running relay whose instance directory was renamed" 's~^    # A relay whose instance directory was renamed or deleted still runs.$~    RUNDIR=/nonexistent~'
mutant "uninstall removes the port records" 's~rm -rf "${DATA:?}" "${RUNDIR:?}"~rm -rf "${DATA:?}"~'

mutant "install without systemd/udp-broadcast-relay@.service writes no addon home" 's~\[ -f "$f" \] || die "missing $f; run install~true || die "missing $f; run install~'
mutant "install without on_boot.d/20-udp-broadcast-relay.sh writes no addon home" 's~"$self/systemd/$UNIT_NAME" "$self/on_boot.d/$ONBOOT_NAME"; do~"$self/systemd/$UNIT_NAME"; do~'
mutant "boot removes a stale temporary boot entry" '/^    no_args boot/,/^    clean_tmp$/{/^    clean_tmp$/d}'
mutant "install removes a stale temporary unit" '/^    no_args install/,/^    clean_tmp$/{/^    clean_tmp$/d}'
mutant "boot removes a stale temporary unit" 's~ "$UNITS/$UNIT_NAME".new.\* \\$~ \\~'
mutant "boot removes a stale temporary file in the home" 's~"$DATA/$PROG".new.\* "$DATA/systemd~"$DATA/systemd~'
mutant "boot keeps a file whose suffix is not a process ID" 's~\*\[!0-9\]\*) continue ;; esac~*.*) continue ;; esac~'
mutant "boot fails when the unit directory cannot be made" 's~|| die "cannot create the directory of $3"~|| return 0~'
mutant "boot leaves no temporary unit after a failed copy" 's~        rm -f "$tmp"$~        :~'
mutant "install without systemd/udp-broadcast-relay@.service says that nothing changed" 's~ Nothing changed."~"~' 
mutant "boot keeps another addon's temporary boot entry" 's~"$ONBOOT/$ONBOOT_NAME".new.\* "$UNITS~"$ONBOOT"/*.new.* "$UNITS~'
mutant "boot keeps another addon's temporary unit" 's~"$UNITS/$UNIT_NAME".new.\* \\$~"$UNITS"/*.new.* \\~'
mutant "boot keeps a file that install never writes" 's~"$INST"/\*/relay.conf.example.new.\*~"$INST"/*/*.new.*~'

echo "$((total - missed)) of $total faults caught"
[ "$missed" -eq 0 ]
