#!/bin/sh
# Redraws the printed artwork with tools/print-art.py (numpy + Pillow, in a venv under build/):
#   tools/make-icon.sh       the App/AppIcon.icon layers, then App/AppIcon.icns, the flat fallback
#                            build.sh uses when actool isn't available
#   tools/make-icon.sh dmg   the DMG window background in tools/dmg/
set -e
cd "$(dirname "$0")/.."
VENV=build/art-venv
[ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import numpy, PIL" 2>/dev/null ||
  { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q numpy pillow; }
if [ "$1" = "dmg" ]; then "$VENV/bin/python" tools/print-art.py dmg; exit; fi

"$VENV/bin/python" tools/print-art.py icon
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
SET=build/AppIcon.iconset
rm -rf "$SET"; mkdir -p "$SET"
for pt in 16 32 128 256 512; do
  "$ICTOOL" App/AppIcon.icon --export-preview macOS Light $pt $pt 1 "$SET/icon_${pt}x${pt}.png" >/dev/null
  "$ICTOOL" App/AppIcon.icon --export-preview macOS Light $pt $pt 2 "$SET/icon_${pt}x${pt}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o App/AppIcon.icns
