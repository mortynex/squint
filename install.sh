#!/bin/sh
# Installs build/Squint.app to /Applications and (re)registers its Quick Look extension.
set -e
cd "$(dirname "$0")"
DEST="/Applications/Squint.app"
pkill -x Squint || true
rm -rf "$DEST"; cp -R build/Squint.app "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/SquintExtension.appex"
pluginkit -e use -i com.martin.Squint.Extension
pkill -f SquintExtension || true
qlmanage -r >/dev/null 2>&1; qlmanage -r cache >/dev/null 2>&1
# Squint's Info.plist claims every type the preview handles, so it opens them unless another app was chosen;
# Settings > Default App lists those (taking a type from another app asks for confirmation, one dialog per type).
echo "Installed $DEST"
