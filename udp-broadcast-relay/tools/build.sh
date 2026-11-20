#!/bin/sh
# Build udp-broadcast-relay-redux from a pinned upstream commit, static,
# for aarch64 (cross) and for x86_64, in an amd64 Debian container.
# Output: dist/<arch>/udp-broadcast-relay-redux and dist/SHA256SUMS.
# The container is always amd64, so every machine builds the same binaries.
# On an arm64 machine docker needs amd64 emulation: Docker Desktop has it;
# on Linux run once: docker run --privileged --rm tonistiigi/binfmt --install amd64
set -eu

PIN=5a5cd384bc944f40ebda3658b08ce0c1c9f00182
UPSTREAM=https://github.com/udp-redux/udp-broadcast-relay-redux.git
# The image digest and the apt snapshot fix every input, so a later build
# gives the hashes in SHA256SUMS. Change them only together with SHA256SUMS.
IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
SNAPSHOT=20261114T000000Z

here=$(cd "$(dirname "$0")/.." && pwd)
dist=$here/dist
rm -rf "$dist"
mkdir -p "$dist/aarch64" "$dist/x86_64"

docker run --rm --platform linux/amd64 -v "$dist:/out" -e PIN="$PIN" -e UPSTREAM="$UPSTREAM" -e SNAPSHOT="$SNAPSHOT" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$IMAGE" sh -eu -c '
  rm -f /etc/apt/sources.list.d/debian.sources
  s=http://snapshot.debian.org/archive
  printf "%s\n" \
    "deb $s/debian/$SNAPSHOT bookworm main" \
    "deb $s/debian/$SNAPSHOT bookworm-updates main" \
    "deb $s/debian-security/$SNAPSHOT bookworm-security main" \
    >/etc/apt/sources.list
  apt-get -o Acquire::Check-Valid-Until=false update -qq
  apt-get install -y -qq --no-install-recommends git ca-certificates gcc \
      libc6-dev gcc-aarch64-linux-gnu libc6-dev-arm64-cross >/dev/null
  git init -q /src && cd /src || exit
  git fetch -q --depth 1 "$UPSTREAM" "$PIN"
  git checkout -q FETCH_HEAD
  test "$(git rev-parse HEAD)" = "$PIN"
  # Fixed flags and no build-id make a repeat build comparable.
  FLAGS="-O2 -static -Wl,--build-id=none"
  aarch64-linux-gnu-gcc $FLAGS main.c -o /out/aarch64/udp-broadcast-relay-redux
  aarch64-linux-gnu-gcc --version | head -1 > /out/aarch64/compiler
  gcc $FLAGS main.c -o /out/x86_64/udp-broadcast-relay-redux
  gcc --version | head -1 > /out/x86_64/compiler
  aarch64-linux-gnu-strip /out/aarch64/udp-broadcast-relay-redux
  strip /out/x86_64/udp-broadcast-relay-redux
  chown -R "$HOST_UID:$HOST_GID" /out
'

(cd "$dist" && sha256sum aarch64/udp-broadcast-relay-redux \
    x86_64/udp-broadcast-relay-redux > SHA256SUMS)
cat "$dist/SHA256SUMS"
# The committed SHA256SUMS is what precheck accepts on the gateway.
if (cd "$dist" && sha256sum -c --quiet "$here/SHA256SUMS" 2>/dev/null); then
    echo "match: the binaries have the hashes in SHA256SUMS"
else
    echo "MISMATCH: the binaries differ from SHA256SUMS" >&2
    exit 1
fi
