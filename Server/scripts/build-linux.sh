#!/bin/bash
# Builds fsdrived for Linux inside a Swift container, bundled with the glibc it was linked
# against and that glibc's own loader. It then runs on any distribution regardless of
# the system glibc — including QTS on QNAP (glibc 2.23).
#
# Why not the fully static musl SDK: its prebuilt runtime uses ARMv8.1 atomics, which
# crash on ARMv8.0 CPUs such as the Cortex-A72 in QNAP TS-x35 models.
#
# usage: scripts/build-linux.sh [aarch64|x86_64]
#   -> build/linux/<arch>/fsdrived            launcher script (run this)
#      build/linux/<arch>/libexec/fsdrived    the program
#      build/linux/<arch>/libexec/lib/      loader + libc, libm, libstdc++, libgcc_s
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH=${1:-aarch64}
case "$ARCH" in
    aarch64) PLATFORM=linux/arm64; LOADER=ld-linux-aarch64.so.1; QEMU_CPU=cortex-a72 ;;
    x86_64) PLATFORM=linux/amd64; LOADER=ld-linux-x86-64.so.2; QEMU_CPU= ;;
    *) echo "unknown arch $ARCH" >&2; exit 1 ;;
esac
SWIFT_IMAGE=swift:6.4.1-noble
OUT=build/linux/$ARCH

rm -rf "$OUT" && mkdir -p "$OUT/libexec/lib"
docker run --rm --platform $PLATFORM -v "$PWD":/src -v fsdrive-swiftpm-$ARCH:/root/.swiftpm -w /src $SWIFT_IMAGE bash -euc "
    swift build -c release --product fsdrived --static-swift-stdlib --scratch-path .build-linux-$ARCH
    BIN=\$(swift build -c release --product fsdrived --static-swift-stdlib --scratch-path .build-linux-$ARCH --show-bin-path)/fsdrived
    cp \$BIN $OUT/libexec/fsdrived
    strip $OUT/libexec/fsdrived
    # Copy every shared library the program needs, plus the loader itself.
    for lib in \$(ldd \$BIN | grep -o '/[^ ]*'); do
        cp -L \$lib $OUT/libexec/lib/
    done
"
cat > "$OUT/fsdrived" <<LAUNCHER
#!/bin/sh
# Runs fsdrived with its bundled C library instead of the system one.
D=\$(dirname "\$(readlink -f "\$0")")
exec "\$D/libexec/lib/$LOADER" --library-path "\$D/libexec/lib" "\$D/libexec/fsdrived" "\$@"
LAUNCHER
chmod +x "$OUT/fsdrived"

# Smoke test on the oldest CPU we target, so an instruction it lacks fails here and
# not on the NAS.
if [ -n "$QEMU_CPU" ] && docker image inspect fsdrive-qemu >/dev/null 2>&1; then
    docker run --rm --platform $PLATFORM -v "$PWD/$OUT":/v fsdrive-qemu \
        qemu-aarch64 -cpu $QEMU_CPU /v/libexec/lib/$LOADER --library-path /v/libexec/lib /v/libexec/fsdrived | head -1
fi
du -sh "$OUT"
ls "$OUT/libexec/lib"
