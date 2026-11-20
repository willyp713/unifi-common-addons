Upstream:   https://github.com/udp-redux/udp-broadcast-relay-redux (GPL-2.0-or-later)
Commit:     5a5cd384bc944f40ebda3658b08ce0c1c9f00182 (2024-01-25, "Update README.md")
Source:     main.c only, compiled unmodified
Builder:    tools/build.sh, in debian:bookworm-slim (linux/amd64 on every
            machine, so arm64 machines give the same hashes), pinned by digest
            (sha256:734a72b3...), with apt from snapshot.debian.org at
            20261114T000000Z
Compilers:  aarch64-linux-gnu-gcc (Debian 12.2.0-14) 12.2.0 (cross)
            gcc (Debian 12.2.0-14+deb12u1) 12.2.0 (host, x86_64)
Flags:      -O2 -static -Wl,--build-id=none, then strip

SHA-256 of the stripped binaries (built 2026-11-14):
d0272c0ff0c6a3d461e517131425c0de2c32e0ae3c6358eb6f0d8d017ba29f10  aarch64/udp-broadcast-relay-redux
51e83e2b10950176f73c3b8c987b1361bfd6c6deecee4cdf4a45d9ee496e0f2b  x86_64/udp-broadcast-relay-redux

The same hashes are in SHA256SUMS. precheck accepts only a binary with the
hash listed there for the gateway's CPU. tools/build.sh stops with an error
if a build gives other hashes.

Reproducibility: the image digest and the apt snapshot fix every input. A
build on 2026-11-14 with both pins gave the same two hashes as the first
build. To move to a newer toolchain, change both pins and SHA256SUMS in one
commit.

The binaries are not committed. They are in dist/, which is git-ignored.
