#!/bin/sh
# Stage 2: install the armv7 TSDuck we just built, then build dantto4k against it.
# Run inside the same armv7 Alpine container image, with /work = dantto4k checkout.
set -e

apk add --no-cache \
    bash coreutils diffutils procps util-linux linux-headers \
    make cmake flex bison g++ dos2unix curl tar zip dpkg python3 \
    zlib-dev zlib-static pcsc-lite-dev git >/dev/null 2>&1

export NODEKTEC=1 NODTAPI=1 NOHIDES=1 NOVATEK=1 \
       NOCURL=1 NOSRT=1 NORIST=1 NOPCSC=1 NOOPENSSL=1 \
       NOJAVA=1 NOPYTHON=1 NOEDITLINE=1 \
       NODOC=1 NODOXYGEN=1 NOTEST=1 NOGITHUB=1

# Must happen in the SAME container as the dantto4k build: this installs into the
# container's /usr, which does not persist. Use the per-library targets so we don't
# drag in tsplugins/tstools, which we deliberately never built.
#
# CAUTION: TSDuck derives BINDIR from $HOSTNAME (scripts/make-config.sh: hpart="-$HOSTNAME"),
# so bin/release-arm-<hostname>. Docker randomises the hostname per container, which makes
# the install look for artifacts in a directory the build never wrote to. Every container
# in this flow must therefore run with the SAME --hostname.
# Do not pipe these into tail: the pipeline would mask a failure from set -e.
echo "=== installing TSDuck (objects already built, should be quick) ==="
make -C /work/thirdparty/tsduck/src/libtscore install-tools install-devel
make -C /work/thirdparty/tsduck/src/libtsduck install-tools install-devel

echo "=== pkg-config check ==="
pkg-config --modversion tsduck
pkg-config --cflags-only-I tsduck
pkg-config --libs tsduck

echo "=== building dantto4k ==="
cd /work
make -j3 2>&1 | tail -60

echo "=== result ==="
ls -la build/dantto4k
file build/dantto4k
echo "=== runtime deps ==="
ldd build/dantto4k || true
