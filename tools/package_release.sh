#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

ace_identity=$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ { print $2; exit }')
if [ -z "$ace_identity" ]; then
    printf '%s\n' 'A Developer ID Application signing identity is required.' >&2
    exit 1
fi

ace_root=.build/release
ACE_BUILD_ROOT="$ace_root" ACE_ARCHS=universal ACE_SIGNING_IDENTITY="$ace_identity" \
    ACE_SIGN_FOR_DISTRIBUTION=1 sh build.sh
ace_app="$ace_root/Ace Control.app"
ace_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ace_app/Contents/Info.plist")
ace_zip="$ace_root/Ace-Control-v$ace_version-macOS-universal.zip"
rm -f "$ace_zip"
ditto -c -k --sequesterRsrc --keepParent "$ace_app" "$ace_zip"

if [ -n "${ACE_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ace_zip" --keychain-profile "$ACE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$ace_app"
    xcrun stapler validate "$ace_app"
    rm -f "$ace_zip"
    ditto -c -k --sequesterRsrc --keepParent "$ace_app" "$ace_zip"
else
    printf '%s\n' 'No ACE_NOTARY_PROFILE set; this archive is signed but not notarized.' >&2
fi

codesign --verify --strict --all-architectures "$ace_app"
shasum -a 256 "$ace_zip"
printf '%s\n' "Release archive: $(cd "$ace_root" && pwd)/$(basename "$ace_zip")"
