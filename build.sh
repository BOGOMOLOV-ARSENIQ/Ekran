#!/bin/bash
# Builds Ekran.app with the Command Line Tools only (no Xcode, no SwiftPM).
# Usage: ./build.sh [--universal] [--debug] [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Ekran
MIN_MACOS=13.0
CONFIG=release
ARCHS=("$(uname -m)")
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) ARCHS=(arm64 x86_64) ;;
        --debug) CONFIG=debug ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

SDK=$(xcrun --show-sdk-path)
SWIFT_SOURCES=()
while IFS= read -r f; do SWIFT_SOURCES+=("$f"); done < <(find Sources/Ekran -name '*.swift' | sort)
C_SOURCES=()
while IFS= read -r f; do C_SOURCES+=("$f"); done < <(find Sources/CPrivate -name '*.m' | sort)

if [ "$CONFIG" = release ]; then
    SWIFT_FLAGS=(-O -wmo)
    C_FLAGS=(-O2)
else
    SWIFT_FLAGS=(-Onone -g)
    C_FLAGS=(-O0 -g)
fi

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
    OUT="build/$CONFIG/$ARCH"
    mkdir -p "$OUT"
    TARGET="$ARCH-apple-macosx$MIN_MACOS"
    OBJECTS=()
    for f in "${C_SOURCES[@]}"; do
        o="$OUT/$(basename "${f%.*}").o"
        clang -c -fobjc-arc -fmodules "${C_FLAGS[@]}" -target "$TARGET" -isysroot "$SDK" \
            -I Sources/CPrivate/include -Wall -Wno-unused-parameter "$f" -o "$o"
        OBJECTS+=("$o")
    done
    swiftc "${SWIFT_FLAGS[@]}" -target "$TARGET" -sdk "$SDK" -swift-version 5 \
        -module-name "$APP_NAME" -I Sources/CPrivate/include \
        "${SWIFT_SOURCES[@]}" "${OBJECTS[@]}" \
        -framework AppKit -framework IOKit -framework CoreGraphics -framework ScreenCaptureKit \
        -framework ColorSync -framework Carbon -framework AVFoundation -framework CoreMedia \
        -framework ServiceManagement -framework Network -framework CoreAudio \
        -o "$OUT/$APP_NAME"
    BINARIES+=("$OUT/$APP_NAME")
done

# "Ekran Keys" helper. macOS ties the Accessibility permission to the helper's exact code signature, so it is
# built only when its own sources change (always universal) and reused byte for byte otherwise: rebuilding Ekran
# never invalidates the permission.
KEYTAP_NAME="Ekran Keys"
KEYTAP_HASH=$( { cat Sources/KeyTap/main.m Resources/KeyTap-Info.plist Resources/AppIcon.icns; echo "$MIN_MACOS"; clang --version | head -1; } \
    | shasum -a 256 | cut -c1-16)
KEYTAP_DIR="build/cache/keytap-$KEYTAP_HASH"
KEYTAP_APP="$KEYTAP_DIR/$KEYTAP_NAME.app"
if [ ! -d "$KEYTAP_APP" ]; then
    rm -rf build/cache/keytap-*
    mkdir -p "$KEYTAP_APP/Contents/MacOS" "$KEYTAP_APP/Contents/Resources"
    for ARCH in arm64 x86_64; do
        clang -fobjc-arc -O2 -Wall -target "$ARCH-apple-macosx$MIN_MACOS" -isysroot "$SDK" \
            Sources/KeyTap/main.m -framework AppKit -framework ApplicationServices -o "$KEYTAP_DIR/EkranKeys-$ARCH"
    done
    lipo -create "$KEYTAP_DIR/EkranKeys-arm64" "$KEYTAP_DIR/EkranKeys-x86_64" -output "$KEYTAP_APP/Contents/MacOS/EkranKeys"
    strip -x "$KEYTAP_APP/Contents/MacOS/EkranKeys"
    cp Resources/KeyTap-Info.plist "$KEYTAP_APP/Contents/Info.plist"
    cp Resources/AppIcon.icns "$KEYTAP_APP/Contents/Resources/AppIcon.icns"
    xattr -cr "$KEYTAP_APP"
    codesign --force --sign - --timestamp=none "$KEYTAP_APP" >/dev/null
fi

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
ditto "$KEYTAP_APP" "$APP/Contents/Helpers/$KEYTAP_NAME.app"
if [ ${#BINARIES[@]} -gt 1 ]; then
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi
[ "$CONFIG" = release ] && strip -x "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ekranctl "$APP/Contents/Resources/ekranctl"
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP (${ARCHS[*]}, $CONFIG)"

if [ "$INSTALL" = 1 ]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP_NAME.app"
fi
