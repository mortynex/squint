#!/bin/sh
# Builds build/Squint.app (ad-hoc signed). Run js/build.sh first if Resources/ is missing.
set -e
cd "$(dirname "$0")"
[ -f Resources/core.js ] || js/build.sh
TARGET=arm64-apple-macos13.0
APP=build/Squint.app
EXT=$APP/Contents/PlugIns/SquintExtension.appex
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"

clang -c -O2 -target $TARGET -I vendor Shared/onigshim.c -o build/onigshim.o

swiftc -O -target $TARGET -swift-version 5 -parse-as-library -module-name SquintExtension -application-extension \
  -import-objc-header Shared/onigshim.h Extension/*.swift Shared/*.swift \
  build/onigshim.o vendor/libonig.a -framework QuickLookUI -framework JavaScriptCore \
  -Xlinker -w -Xlinker -e -Xlinker _NSExtensionMain -o "$EXT/Contents/MacOS/SquintExtension"

swiftc -O -target $TARGET -swift-version 5 -module-name Squint -import-objc-header Shared/onigshim.h \
  App/*.swift App/Editor/*.swift Shared/*.swift Extension/Palette.swift Extension/LineNumberGutterView.swift Extension/GlassBackground.swift Extension/PreviewRootView.swift \
  build/onigshim.o vendor/libonig.a -framework SwiftUI -framework JavaScriptCore -Xlinker -w -o "$APP/Contents/MacOS/Squint"

cp Extension/Info.plist "$EXT/Contents/Info.plist"
cp App/Info.plist "$APP/Contents/Info.plist"
[ -f App/AppIcon.icns ] && cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/. "$EXT/Contents/Resources/"

codesign --force --sign - --entitlements Extension/Extension.entitlements "$EXT"
codesign --force --sign - --entitlements App/App.entitlements "$APP"
echo "Built $APP"
