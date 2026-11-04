#!/bin/bash
# Builds the Synology Package Center package: build/spk/FSDrive_<ver>_x86_64.spk (and
# _armv8 for ARM64 models with --arm). The Linux binary comes from scripts/build-linux.sh;
# an SPK is a plain tar of INFO, package.tgz (what lands in /var/packages/FSDrive/target),
# scripts/, conf/ and the package icons, so no Synology toolkit is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(x86_64)
[ "${1:-}" = "--arm" ] && ARCHS+=(aarch64)

SRC=Packaging/synology
VERSION=$(sed -n 's/^version="\(.*\)"/\1/p' $SRC/INFO)
QNAP_VERSION=$(sed -n 's/^QPKG_VER="\(.*\)"/\1/p' Packaging/qnap/qpkg.cfg)
[ "${VERSION%-*}" = "$QNAP_VERSION" ] || { echo "version $VERSION in $SRC/INFO differs from QNAP $QNAP_VERSION" >&2; exit 1; }

for arch in "${ARCHS[@]}"; do scripts/build-linux.sh "$arch"; done

OUT=build/spk
mkdir -p $OUT
ICON=../Design/AppIcon.png
for arch in "${ARCHS[@]}"; do
    spkarch=$([ "$arch" = aarch64 ] && echo armv8 || echo x86_64)
    STAGE=$OUT/stage-$spkarch
    rm -rf "$STAGE" && mkdir -p "$STAGE/target/bin" "$STAGE/target/ui/images" "$STAGE/spk"

    # package.tgz: the program, the root part, the settings page and the firewall entry.
    cp -R "build/linux/$arch/fsdrived" "build/linux/$arch/libexec" "$STAGE/target/bin/"
    cp $SRC/bin/* "$STAGE/target/bin/"
    cp Packaging/qnap/shared/gateway-setup.sh "$STAGE/target/bin/"
    cp -R $SRC/app "$STAGE/target/"
    cp $SRC/ui/config $SRC/ui/index.html $SRC/ui/fsdrive.cgi "$STAGE/target/ui/"
    for size in 16 24 32 48 64 72 256; do
        sips -z $size $size "$ICON" --out "$STAGE/target/ui/images/fsdrive_$size.png" >/dev/null
    done
    chmod 755 "$STAGE/target/bin/"* "$STAGE/target/ui/fsdrive.cgi"
    COPYFILE_DISABLE=1 tar czf "$STAGE/spk/package.tgz" --uid 0 --gid 0 -C "$STAGE/target" .

    sed "s/^version=.*/version=\"$VERSION\"/" $SRC/INFO > "$STAGE/spk/INFO"
    echo "arch=\"$spkarch\"" >> "$STAGE/spk/INFO"
    cp -R $SRC/scripts $SRC/conf "$STAGE/spk/"
    chmod 755 "$STAGE/spk/scripts/"*
    sips -z 64 64 "$ICON" --out "$STAGE/spk/PACKAGE_ICON.PNG" >/dev/null
    sips -z 256 256 "$ICON" --out "$STAGE/spk/PACKAGE_ICON_256.PNG" >/dev/null
    (cd "$STAGE/spk" && COPYFILE_DISABLE=1 tar cf "../../FSDrive_${VERSION%-*}_$spkarch.spk" --uid 0 --gid 0 \
        INFO package.tgz scripts conf PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG)
    rm -rf "$STAGE"
done
ls -lh $OUT/*.spk
echo "version $VERSION"
