#!/bin/bash
set -euo pipefail
cd "$SRCROOT/../zig-core"
zig build -Doptimize=ReleaseFast
mkdir -p "$BUILT_PRODUCTS_DIR"
cp zig-out/lib/libtemperplayer.dylib "$BUILT_PRODUCTS_DIR/"
install_name_tool -id "@rpath/libtemperplayer.dylib" "$BUILT_PRODUCTS_DIR/libtemperplayer.dylib"
