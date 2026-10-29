#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$ROOT/build/Payload/hidgate4.app"

rm -rf "$ROOT/build"
mkdir -p "$OUT"

xcrun --sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$SDK" \
    -fobjc-arc -fblocks -O2 \
    -c "$ROOT/PoC/main.m" \
    -o "$ROOT/build/main.o"

xcrun --sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$SDK" \
    -o "$OUT/hidgate4" \
    "$ROOT/build/main.o" \
    -framework UIKit -framework Foundation -framework IOKit

cp "$ROOT/PoC/Info.plist" "$OUT/Info.plist"
chmod +x "$OUT/hidgate4"

echo "Built: $OUT"
echo "Sign and install with your normal sideloading workflow."
