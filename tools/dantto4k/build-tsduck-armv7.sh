#!/bin/sh
# Build TSDuck inside an armv7 Alpine container (qemu-emulated).
# Goal: prove TSDuck builds for armv7/musl, and produce libtsduck.a/.so for dantto4k.
set -e

echo "=== arch: $(uname -m)  alpine: $(cat /etc/alpine-release) ==="

apk add --no-cache \
    bash coreutils diffutils procps util-linux linux-headers \
    git make cmake flex bison g++ dos2unix curl tar zip dpkg python3 \
    zlib-dev zlib-static >/dev/null

echo "=== g++: $(g++ --version | head -1) ==="

cd /work/thirdparty/tsduck

# Strip every optional external dependency: dantto4k only needs SI tables,
# descriptors and the packetizer. Fewer deps => static linking is feasible.
export NODEKTEC=1 NODTAPI=1 NOHIDES=1 NOVATEK=1 \
       NOCURL=1 NOSRT=1 NORIST=1 NOPCSC=1 NOOPENSSL=1 \
       NOJAVA=1 NOPYTHON=1 NOEDITLINE=1 \
       NODOC=1 NODOXYGEN=1 NOTEST=1 NOGITHUB=1

echo "=== make-config summary ==="
make listvars 2>/dev/null | grep -E "^(MAIN_ARCH|CXX|CXXFLAGS|BINDIR|LDLIBS|ALPINE|LINUX|USE_GCC) = " | head -20 || true

echo "=== building (this is qemu-emulated, expect it to be slow) ==="
make -j3 2>&1 | tail -400

echo "=== build finished, artifacts: ==="
find bin -maxdepth 2 -name "libts*" -o -maxdepth 2 -name "tsp" | head -20
ls -la bin/*/ 2>/dev/null | head -30
