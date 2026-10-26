#!/bin/sh
# Builds a release of the version in VERSION into build/release/:
#   Squint-<version>.dmg       – for people to download (drag Squint to Applications)
#   Squint-<version>.zip       – what the in-app updater downloads
#   Squint-<version>.zip.sig   – its Ed25519 signature (key: see tools/update-key.swift)
# ./release.sh --publish also tags v<version>, pushes the tag and creates the GitHub release with those files
# (notes: RELEASE_NOTES, else generated from the commits).
# With SIGN_IDENTITY (a Developer ID Application certificate) and NOTARY_PROFILE (a `xcrun notarytool
# store-credentials` profile) set, the app and DMG are notarized and stapled as well.
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
OUT=build/release
NAME=Squint-$VERSION

if [ "$1" = "--publish" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION is already tagged; bump VERSION." >&2; exit 1; }
fi

./build.sh
rm -rf "$OUT"; mkdir -p "$OUT"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  ditto -c -k --keepParent build/Squint.app "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  xcrun stapler staple build/Squint.app
  rm "$OUT/notarize.zip"
fi

ditto -c -k --keepParent build/Squint.app "$OUT/$NAME.zip"
swift tools/update-key.swift sign "$OUT/$NAME.zip" > "$OUT/$NAME.zip.sig"

STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R build/Squint.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Squint $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/$NAME.dmg"
rm -rf "$STAGE"
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/$NAME.dmg"
  if [ -n "$NOTARY_PROFILE" ]; then notarize "$OUT/$NAME.dmg"; xcrun stapler staple "$OUT/$NAME.dmg"; fi
fi
echo "Built $OUT/$NAME.dmg, .zip and .zip.sig"

if [ "$1" = "--publish" ]; then
  git tag "v$VERSION"
  git push origin "v$VERSION"
  set -- "$OUT/$NAME.dmg" "$OUT/$NAME.zip" "$OUT/$NAME.zip.sig" --title "Squint $VERSION"
  if [ -n "$RELEASE_NOTES" ]; then gh release create "v$VERSION" "$@" --notes "$RELEASE_NOTES"
  else gh release create "v$VERSION" "$@" --generate-notes; fi
fi
