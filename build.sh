#!/bin/sh
set -eu
cd "$(dirname "$0")"
ace_build_root=${ACE_BUILD_ROOT:-.build}
ace_deployment_target=${ACE_DEPLOYMENT_TARGET:-13.0}
ace_archs=${ACE_ARCHS:-$(uname -m)}
case "$ace_archs" in
    universal) ace_archs='arm64 x86_64' ;;
    arm64|x86_64) ;;
    *) printf '%s\n' 'ACE_ARCHS must be arm64, x86_64, or universal.' >&2; exit 1 ;;
esac
ace_app="$ace_build_root/Ace Control.app"
mkdir -p "$ace_app/Contents/MacOS" "$ace_app/Contents/Resources" "$ace_build_root"
for ace_arch in $ace_archs; do
    mkdir -p "$ace_build_root/module-cache/$ace_arch"
    swiftc -swift-version 5 -target "$ace_arch-apple-macos$ace_deployment_target" \
        -module-cache-path "$ace_build_root/module-cache/$ace_arch" \
        -framework AppKit -framework Carbon -framework CoreBluetooth -framework Security -framework AVFoundation \
        "$PWD/SonosProtocol.swift" "$PWD/SonosAttestation.swift" "$PWD/CallAudioTest.swift" \
        "$PWD/MenuControls.swift" "$PWD/KeyboardShortcuts.swift" "$PWD/ExtraSettings.swift" \
        "$PWD/main.swift" -o "$ace_build_root/AceControl-$ace_arch"
done
if [ "$ace_archs" = 'arm64 x86_64' ]; then
    lipo -create "$ace_build_root/AceControl-arm64" "$ace_build_root/AceControl-x86_64" \
        -output "$ace_app/Contents/MacOS/AceControl"
else
    cp "$ace_build_root/AceControl-$ace_archs" "$ace_app/Contents/MacOS/AceControl"
fi
iconset="$ace_build_root/AceControl.iconset"
mkdir -p "$iconset"
swiftc -swift-version 5 -module-cache-path "$ace_build_root/module-cache" -framework AppKit \
    tools/generate_app_icon.swift -o "$ace_build_root/generate-app-icon"
"$ace_build_root/generate-app-icon" "$ace_build_root/AceControl-1024.png"
for side in 16 32 128 256 512; do
    double_side=$((side * 2))
    sips -z "$side" "$side" "$ace_build_root/AceControl-1024.png" --out "$iconset/icon_${side}x${side}.png" >/dev/null
    sips -z "$double_side" "$double_side" "$ace_build_root/AceControl-1024.png" --out "$iconset/icon_${side}x${side}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$ace_app/Contents/Resources/AceControl.icns"
cat > "$ace_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AceControl</string>
<key>CFBundleIdentifier</key><string>local.hedworth.ace-control</string>
<key>CFBundleName</key><string>Ace Control</string>
<key>CFBundleIconFile</key><string>AceControl.icns</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>LSMinimumSystemVersion</key><string>$ace_deployment_target</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Read and change your Sonos Ace headphone settings over Bluetooth.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Read and change your Sonos Ace headphone settings over Bluetooth.</string>
<key>NSMicrophoneUsageDescription</key><string>Open the Sonos headphone microphone to test sidetone in call audio mode. Audio is discarded, never recorded or sent.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A stable signing identity lets macOS retain Bluetooth/microphone permissions
# across rebuilds. Ad-hoc signing binds permissions to a single binary hash.
# ACE_SIGNING_IDENTITY can select a particular certificate on another Mac.
ace_signing_identity=${ACE_SIGNING_IDENTITY:-}
if [ -z "$ace_signing_identity" ]; then
    ace_signing_identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')
fi
if [ -z "$ace_signing_identity" ]; then
    ace_signing_identity=-
    printf '%s\n' 'No Apple Development identity found; using ad-hoc signing. Permission prompts may recur after rebuilding.' >&2
fi
if [ "${ACE_SIGN_FOR_DISTRIBUTION:-0}" = 1 ]; then
    if [ "$ace_signing_identity" = - ]; then
        printf '%s\n' 'Distribution requires a Developer ID Application signing identity.' >&2
        exit 1
    fi
    codesign --force --options runtime --timestamp --sign "$ace_signing_identity" "$ace_app"
else
    codesign --force --sign "$ace_signing_identity" "$ace_app"
fi
codesign --verify --strict --all-architectures "$ace_app"
"$ace_app/Contents/MacOS/AceControl" --self-test
printf '%s\n' "Built: $(cd "$ace_build_root" && pwd)/Ace Control.app"
