#!/bin/sh
# Renders App/AppIcon.icon (the Liquid Glass icon, edit it in Icon Composer) into App/AppIcon.icns,
# the flat fallback build.sh uses when actool isn't available.
# Usage: tools/make-icon.sh
set -e
cd "$(dirname "$0")/.."
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
SET=build/AppIcon.iconset
rm -rf "$SET"; mkdir -p "$SET"
for pt in 16 32 128 256 512; do
  "$ICTOOL" App/AppIcon.icon --export-preview macOS Light $pt $pt 1 "$SET/icon_${pt}x${pt}.png" >/dev/null
  "$ICTOOL" App/AppIcon.icon --export-preview macOS Light $pt $pt 2 "$SET/icon_${pt}x${pt}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o App/AppIcon.icns
