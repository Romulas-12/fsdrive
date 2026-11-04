#!/bin/bash
# Builds the QNAP App Center package: build/qpkg/FSDrive_<ver>_arm_64.qpkg (and x86_64 with --x86).
# The static Linux binary comes from scripts/build-linux.sh; packaging uses QNAP's QDK.
set -euo pipefail
cd "$(dirname "$0")/.."

QDK_COMMIT=b7b5f4c
ARCHS=(aarch64)
[ "${1:-}" = "--x86" ] && ARCHS+=(x86_64)

for arch in "${ARCHS[@]}"; do scripts/build-linux.sh "$arch"; done

if [ ! -d build/QDK ]; then
    git clone -q https://github.com/qnap-dev/QDK.git build/QDK
    git -C build/QDK checkout -q "$QDK_COMMIT"
fi

STAGE=build/qpkg/FSDrive
rm -rf "$STAGE" && mkdir -p "$STAGE/config"
cp -R Packaging/qnap/qpkg.cfg Packaging/qnap/package_routines Packaging/qnap/shared Packaging/qnap/icons "$STAGE/"
VERSION=$(sed -n 's/^QPKG_VER="\(.*\)"/\1/p' Packaging/qnap/qpkg.cfg)
BUILD_ARCHS=()
for arch in "${ARCHS[@]}"; do
    qarch=$([ "$arch" = aarch64 ] && echo arm_64 || echo x86_64)
    mkdir -p "$STAGE/$qarch"
    cp -R "build/linux/$arch/fsdrived" "build/linux/$arch/libexec" "$STAGE/$qarch/"
    BUILD_ARCHS+=("$qarch")
done

# QDK needs rsync, which the Swift image lacks.
docker build -q --platform linux/arm64 -t fsdrive-qdk - >/dev/null <<'DOCKERFILE'
FROM swift:6.4.1-noble
RUN apt-get update && apt-get install -y --no-install-recommends rsync && rm -rf /var/lib/apt/lists/*
DOCKERFILE

docker run --rm --platform linux/arm64 -v "$PWD":/src -v "$PWD/build/QDK/shared":/usr/share/QDK:ro -w /src/$STAGE \
    fsdrive-qdk bash -euc "
    mkdir -p /etc/config
    sed -e '2d' /usr/share/QDK/qdk.conf | sed '2iQDK_PATH_P=/usr/share' > /etc/config/qdk.conf
    clang -O2 -o /usr/local/bin/qpkg_encrypt /src/build/QDK/src/qpkg_encrypt.c
    for a in ${BUILD_ARCHS[*]}; do /usr/share/QDK/bin/qbuild -v --build-arch \$a --build-dir /src/build/qpkg; done
"
ls -lh build/qpkg/*.qpkg
echo "version $VERSION"
