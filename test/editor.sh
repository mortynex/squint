#!/bin/sh
# Headless editor tests: test/editor.sh (builds build/editor-tests with the app's sources and runs it).
set -e
cd "$(dirname "$0")/.."
[ -f Resources/core.js ] || js/build.sh
mkdir -p build
clang -c -O2 -target arm64-apple-macos13.0 -I vendor Shared/onigshim.c -o build/onigshim.o
APP_SOURCES=$(ls App/*.swift | grep -v App/main.swift)
swiftc -O -target arm64-apple-macos13.0 -swift-version 5 -module-name SquintTests -import-objc-header Shared/onigshim.h \
  $APP_SOURCES App/Editor/*.swift Shared/*.swift Extension/Palette.swift Extension/LineNumberGutterView.swift \
  Extension/GlassBackground.swift Extension/PreviewRootView.swift test/editor/main.swift \
  build/onigshim.o vendor/libonig.a -framework SwiftUI -framework JavaScriptCore -Xlinker -w -o build/editor-tests
./build/editor-tests "$PWD" "$@"
