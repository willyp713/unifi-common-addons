# UDP broadcast relay (udp-broadcast-relay)

Some apps find their devices with a UDP broadcast on their own network. A
router does not forward a broadcast, so when the app and the device are on
different VLANs, the app finds nothing, and no firewall rule can change
that. This addon runs a relay on the gateway, which is on every VLAN. The
relay copies the broadcasts on one UDP port from the client networks to the
device's network.

The worked example in this README is HDHomeRun: the HDHomeRun app on a
client VLAN finds a tuner on an IoT VLAN. Other discovery protocols that
use a UDP broadcast on a fixed port work the same way.

The relay program is
[udp-broadcast-relay-redux](https://github.com/udp-redux/udp-broadcast-relay-redux).
It keeps the original sender address of each packet, so the device answers
the app directly. The addon runs it as a systemd unit, checks the setup
before each start, and starts it again after a reboot and after a firmware
update.

## The short version

1. Build the relay binary on a computer with docker.
2. Copy the addon to the gateway and run `install`.
3. Write a config: the port, the interfaces, and the broadcast address of
   the device's network.
4. Add one firewall rule, so that the device's answer reaches the app.
5. `enable` the instance.

## Requirements

- A UniFi gateway with
  [unifi-common](https://github.com/unifi-utilities/unifi-common)
  installed. unifi-common needs UniFi OS 4.x or later. UniFi OS 4.x and
  later are built on Debian 11 (bullseye), 12 (bookworm), or 13 (trixie).
  The addon supports all three.
- SSH access to the gateway as `root`.
- A computer with docker, to build the binary. The binary is not in git.
- The device has a fixed address (a DHCP reservation is enough), so that
  the firewall rule can name it.

## How it works

1. The app on a client network sends a broadcast to the port, for example
   UDP 65001 for HDHomeRun.
2. The relay receives it on the client network's interface. It sends a
   copy on each other listed interface, with the original source address
   and port, to the broadcast address in `TARGET`.
3. The device answers by unicast to the app's address. The gateway routes
   the answer like any other packet.
4. The gateway's firewall does not see the answer as return traffic,
   because the app never sent a packet to the device's address. One allow
   rule lets it through (step 5 of "Install").
5. After discovery, the app talks to the device by unicast. Your firewall
   must already allow that from the client network.

The relay marks its own copies with the instance `ID` (it sets the TTL to
`ID` + 64), so that it does not copy them again. It also drops any other
packet that arrives with that TTL.

**Why `TARGET`:** UniFi OS sets no broadcast address on its bridge
interfaces. Without `TARGET`, the relay sends its copies to `0.0.0.0`, and
the device never sees them. `precheck` checks that `TARGET` is the
broadcast address of a network on one of the listed interfaces.

## Install

1. **Build the binaries.** On a computer with docker, from this directory:

   ```sh
   tools/build.sh
   ```

   It builds a static binary for `aarch64` (UniFi gateways) and one for
   `x86_64` (for the tests). It stops with an error if a binary does not
   have the hash listed in `SHA256SUMS`. The build is pinned: the source
   commit, the image digest, and the Debian package snapshot are in
   `BUILD`. The build container is always amd64, so on an arm64 computer
   docker needs amd64 emulation. Docker Desktop has it. On Linux, run once:
   `docker run --privileged --rm tonistiigi/binfmt --install amd64`.

2. **Copy the addon to the gateway.** Put the binary at
   `bin/<arch>/udp-broadcast-relay-redux` in the copy. `<arch>` is the
   output of `uname -m` on the gateway: `aarch64` on most UniFi gateways.

   ```sh
   arch=aarch64    # the output of uname -m on the gateway
   mkdir -p "bin/$arch"
   cp "dist/$arch/udp-broadcast-relay-redux" "bin/$arch/"
   scp -r . root@<gateway>:/tmp/ubr
   ```

3. **Install.** On the gateway:

   ```sh
   /tmp/ubr/udp-broadcast-relay install
   rm -r /tmp/ubr
   ```

   `install` copies the addon to
   `/data/unifi-common-addons/udp-broadcast-relay/`, writes the boot entry
   and the unit, and starts nothing. After this, the command is
   `/data/unifi-common-addons/udp-broadcast-relay/udp-broadcast-relay`.
   The examples below shorten it to `udp-broadcast-relay`.

4. **Write the config.** Find the interface names and addresses:

   ```sh
   ip -br addr
   ```

   On UniFi OS, each network has a bridge, such as `br0` for the default
   network and `br30` for VLAN 30. An instance is a directory in
   `instances/`. Copy the example and edit it:

   ```sh
   cd /data/unifi-common-addons/udp-broadcast-relay/instances/hdhr
   cp relay.conf.example relay.conf
   vi relay.conf
   ```

   | Key | Meaning |
   |---|---|
   | `ID` | A number from 1 to 99, but not 64. The relay marks its own copies with TTL `ID` + 64 and drops each packet with that TTL. With 64, that is 128, the default TTL of Windows. |
   | `PORT` | The UDP port of the discovery broadcast. Each active instance needs a different port. |
   | `DEVS` | The client interfaces and the device's interface: two or more names, in quotes, separated by spaces. |
   | `TARGET` | The broadcast address of the device's network. For `192.168.30.1/24` it is `192.168.30.255`. |

   For HDHomeRun, with clients on `br0` (`192.168.1.1/24`) and the tuner
   on `br30` (`192.168.30.1/24`):

   ```
   ID=1
   PORT=65001
   DEVS="br0 br30"
   TARGET=192.168.30.255
   ```

5. **Add the firewall rule.** In UniFi Network, allow from the device to
   the client network:

   - Source: the device (its address or MAC).
   - Protocol: UDP, source port `PORT` (65001 for HDHomeRun). Do not
     choose "All". With TCP allowed, the device could open any connection
     into the client network from that port.
   - Destination: the client network, any port.

   With zone-based firewall, this is a policy from the device's zone to
   the clients' zone. If your firewall already allows all traffic from the
   device's network to the client network, you need no new rule.

6. **Enable.**

   ```sh
   udp-broadcast-relay enable hdhr
   ```

   `enable` runs `precheck`, and it starts the instance only if every
   check passes.

   To change the config of an enabled instance, edit `relay.conf`, then
   run `disable` and `enable`. `enable` checks the new config. The
   running relay keeps the old values until it restarts.

## Check that it works

```sh
udp-broadcast-relay status
journalctl -u udp-broadcast-relay@hdhr
```

`status` shows the boot entry, the unit, whether the binary has the hash in
`SHA256SUMS`, and the state of each instance. It changes nothing.

Then open the app on a client network. It must find the device.

## Update the addon

Copy the new version of this directory to the gateway, with the binary in
`bin/<arch>/`, and run `install` from that copy. `install` replaces the
script, the unit, and `SHA256SUMS`. It keeps each `relay.conf`. Then
`disable` and `enable` each instance.

`precheck` needs `SHA256SUMS` and accepts only a binary that has the hash
listed there. If you copy only the script, or only the binary, the relay
does not start.

## After a firmware update

The addon is in `/data`, which an update keeps. The boot entry installs the
unit again and starts each active instance. After each update, run
`udp-broadcast-relay status` and open the app once. If the unit is missing,
run `udp-broadcast-relay boot`.

## Remove the addon

- Stop one instance and keep its config: `udp-broadcast-relay disable hdhr`.
  Then delete the firewall rule.
- Remove everything: `udp-broadcast-relay uninstall`. It stops each
  instance and removes the unit, the boot entry, and
  `/data/unifi-common-addons/udp-broadcast-relay/`. Nothing else on the
  gateway changes. Then delete the firewall rule.

## Troubleshooting

**`precheck` fails.** Its message names the cause. It fails when:

- a value in `relay.conf` is missing or wrong,
- an interface does not exist, is down, or is a loopback interface (the
  relay skips such an interface without an error, so `precheck` refuses
  it),
- `TARGET` is not the broadcast address of a network on a listed
  interface,
- another active instance uses the same `PORT`,
- the binary does not have the hash in `SHA256SUMS` for this CPU, or it
  does not run on this CPU. `precheck` checks the hash before it runs the
  binary.

The unit runs `precheck` before each start and tries again after 30
seconds, so a fixed config starts by itself.

**The app finds nothing, but `status` shows the unit active.**

1. Check the firewall rule, and that the device still has its address.
2. Watch the device's interface: `tcpdump -ni br30 udp port 65001`. Open
   the app. You should see the query to `TARGET` and an answer from the
   device.
3. To see the relay's own view, stop the instance and run the relay by
   hand with `-d`:

   ```sh
   udp-broadcast-relay disable hdhr
   /data/unifi-common-addons/udp-broadcast-relay/bin/aarch64/udp-broadcast-relay-redux \
       -d --id 1 --port 65001 --dev br0 --dev br30 -t 192.168.30.255
   ```

   Stop it with Ctrl-C, then `udp-broadcast-relay enable hdhr`.

> [!WARNING]
> Never run two relays on one port. Two relays with different IDs copy
> each other's packets without end, which floods both networks. `precheck`
> refuses a second instance on the same port, but it reads only the
> addon's configs. It cannot see a relay started by hand. Stop any relay
> started by hand before `enable`.

**Test from a client, not from a server with its own firewall.** A host
firewall (for example `ufw`) drops the device's answer, because it is not
return traffic for that host either.

## Reference

### Commands

| Command | What it does |
|---|---|
| `install` | Copy the addon to `/data`, write the boot entry and the unit. Starts nothing. |
| `enable <name>` | Run `precheck`, mark the instance active, and start it. |
| `disable <name>` | Stop the instance and remove its active mark. Keeps the config. |
| `uninstall` | Stop all instances. Remove the unit, the boot entry, and the addon directory. |
| `status` | Show the addon and each instance. Changes nothing. |
| `precheck <name>` | Check the config, the interfaces, the target, the port, and the binary. Changes nothing. |
| `boot` | Install the unit again and start each active instance. The boot entry calls it. |
| `run <name>` | Run the relay in the foreground. The unit calls it. |

`install`, `boot`, `enable`, `disable`, and `uninstall` take a lock
(`/run/udp-broadcast-relay.lock`), so that two of them never run at the
same time.

### Files on the gateway

| Path | What |
|---|---|
| `/data/unifi-common-addons/udp-broadcast-relay/` | The addon home: script, unit source, boot entry source, `SHA256SUMS` |
| `<home>/bin/<arch>/udp-broadcast-relay-redux` | The relay binary |
| `<home>/instances/<name>/relay.conf` | The config of one instance |
| `<home>/instances/<name>/active` | Present while the instance is enabled |
| `/data/on_boot.d/20-udp-broadcast-relay.sh` | The boot entry |
| `/etc/systemd/system/udp-broadcast-relay@.service` | The unit. A firmware update removes it, and `boot` writes it again. |

## Limits and support

- **One device network for each instance.** The relay sends every copy to
  `TARGET`, on each listed interface. A copy that goes out on a client
  network has the device network's broadcast address, so no host there
  takes it. Discovery therefore works from the client networks to the
  device network, not back. List as many client networks as you need in
  `DEVS`.
- **IPv4 only.**
- **The relay runs as root**, because it needs raw sockets. `precheck`
  accepts only a binary with a hash from `SHA256SUMS`.
- **The relay starts once.** If UniFi OS creates a bridge again (for
  example after you change a network), the relay may keep its old
  sockets while the unit still shows active. After a network change, check
  the app. If it finds nothing, `disable` and `enable` the instance.
- The addon shares no file, unit, or directory with any other addon.

## Tested configurations

| Gateway | UniFi OS | Debian | Test | Result |
|---|---|---|---|---|
| UDM Pro | 6.0.17 | 13 | HDHomeRun FLEX 4K, Apple TV and iPhone apps | pass |
| UDM Pro | 6.0.17 | 13 | Reboot: relay started by itself, apps found the tuner | pass |

Off the gateway:

- `tests/run.sh` tests the control script on a fixture root, with stubs
  for `systemctl` and `ip`.
- `tests/mutate.sh` breaks the script on purpose, one fault at a time, and
  checks that `tests/run.sh` catches each one.
- `tests/relay-netns.sh` runs the real relay in a private network namespace
  (`unshare -rn`, no sudo): one copy, the original source address, no
  loop. It needs `dist/<arch>/` from `tools/build.sh`.
- `tests/debian.sh` runs `tests/run.sh` as root in Debian 11, 12, and 13
  containers, and checks that the static binary starts in each. It needs
  docker and `dist/<arch>/`.

`tests/debian.sh` and `tests/relay-netns.sh` pass on amd64 and on arm64
(a Raspberry Pi). The script suite passes in Debian 11, 12, and 13
userlands, and the static `aarch64` binary relays correctly on an arm64
kernel. The containers share the host kernel, so these tests do not stand
in for a gateway's kernel.

Not tested: a firmware update, other gateway models, Debian 11 and 12 on a
gateway, and a bridge created again while the relay runs.

## Compared with the archived `hdhomerun` script

The archived
[unifios-utilities `hdhomerun`](https://github.com/unifi-utilities/unifios-utilities-archived/tree/main/hdhomerun)
script solved the same problem in a different way. Its boot script starts
`socat` with `udp4-recvfrom:65001,broadcast,fork udp4-sendto:<tuner>:65001`.
`socat` receives each discovery broadcast and sends it by unicast to one
tuner address. The tuner's answer goes back through `socat`.

That design has two advantages over this addon:

- The discovery answer returns through `socat`, so it needs no rule for
  that answer (step 5 of "Install").
- It sends to the tuner's own address, so the missing broadcast address
  on UniFi OS bridges (see `TARGET`) does not affect it.

This addon changes the following:

| | Archived script | This addon |
|---|---|---|
| Start and restart | The boot script starts `socat` in the background. Nothing starts it again after it exits. | A systemd unit runs the relay, with `precheck` before each start, and starts it again after an exit. |
| UniFi OS version | The script reads `ubnt-device-info firmware` to find `/data`. It accepts only version numbers that start with 1 to 5, and stops with an error for any other. On a UDM Pro with UniFi OS 6.0.17, the command prints `6.0.17`, so the script stops before it starts `socat`. | No version check. The script is tested on Debian 11, 12, and 13 userlands, the base of UniFi OS 4.x and later. |
| Settings | The tuner address is written in the script. | A config file, read as data and checked before each start. |
| Interfaces | `socat` forwards a packet on the port from any interface. | The relay copies only packets that arrive on an interface in `DEVS`. |
| Devices | One fixed tuner address. | Every device on the target network can answer. The device needs a fixed address only for the firewall rule. |
| Sender address of the answer | The gateway, because `socat` forwards the answer. The archived README reports that this works with an HDHomeRun PRIME. We did not test `socat` with other apps. | The device, because it answers the app directly. |
| Binary | A prebuilt binary in git. Its version strings say socat 1.7.4.3 with OpenSSL 1.0.1k (January 2015), linked statically, although the Dockerfile names OpenSSL 1.0.2k. The Dockerfile downloads the sources with `curl -k`, over HTTP and FTP, with no checksum. | No binary in git. `tools/build.sh` builds from a pinned source commit, in a container image pinned by digest, with packages from a dated Debian snapshot. `precheck` runs only a binary whose hash is in `SHA256SUMS`. |
| Log | `socat -d -d -v` writes each packet's content to the log. | The relay logs nothing for each packet unless you start it by hand with `-d`. |

## Credits and license

- [udp-broadcast-relay-redux](https://github.com/udp-redux/udp-broadcast-relay-redux)
  does the relaying. It is GPL-2.0-or-later. The addon builds it from the
  pinned commit in `BUILD` and does not change it. If you give a binary to
  someone, give them that source too.
- The archived
  [unifios-utilities `hdhomerun`](https://github.com/unifi-utilities/unifios-utilities-archived/tree/main/hdhomerun)
  script solved the same problem first, with a `socat` proxy. See
  "Compared with the archived `hdhomerun` script".
