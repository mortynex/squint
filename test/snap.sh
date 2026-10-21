#!/bin/sh
# Offscreen snapshot harness: test/snap.sh <file> <out.png> [dark] [opaque]
cd "$(dirname "$0")/.."
mkdir -p build
clang -c -O2 -I vendor Shared/onigshim.c -o build/onigshim.o
swiftc -O -swift-version 5 -import-objc-header Shared/onigshim.h Shared/*.swift Extension/*.swift test/snap/main.swift \
  build/onigshim.o vendor/libonig.a -framework QuickLookUI -framework JavaScriptCore -Xlinker -w -o build/snap 2>&1 | grep -E "error" -A3
./build/snap "$@"
