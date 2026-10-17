# Sonos Ace Control

An independent native macOS controller for Sonos headphones over Bluetooth LE,
tested with Sonos Ace Ultra. Built with Swift, AppKit and CoreBluetooth.

<img width="576" height="648" alt="image" src="https://github.com/user-attachments/assets/ee3c6a3e-576d-40ab-af83-055f6e7eb8bd" />

## Features

- Menu bar headphone icon with battery level.
- Tick Shortcut beside a switch or Noise control to add it to the Shortcuts tab;
  record a key combination for each selected control. Choose which noise modes
  its shortcut cycles through, such as Noise cancelling and Aware only.
- Optional auto-connect to the last successfully connected headphones.
- Noise control, sidetone, loudness, and basic/advanced equalizer controls.
- Additional audio, wear detection, button, power, voice and device settings.
- Settings changes verified by reading their values back from the headphones.
- A main window that can be closed while the menu bar controls keep running.

## Download and install

Download the macOS ZIP from [Releases](https://github.com/Bigsy/sonos-ace-control/releases),
unzip it, and move **Ace Control.app** to Applications. The release build supports
Apple silicon and Intel Macs running macOS 13 or later. Open the app and allow
Bluetooth access when macOS asks.

Release ZIPs are Developer ID-signed but have not been notarized by Apple.
macOS may block its first launch. If you trust this project's download and
choose to open it, try opening the app, then use **System Settings → Privacy &
Security → Open Anyway** as described in [Apple's instructions](https://support.apple.com/en-gb/102445).

## Build from source

Requires macOS 13 or later and the Swift compiler/macOS SDK supplied by Xcode or
its Command Line Tools (`xcode-select --install`). No third-party build
dependencies are required.

```sh
git clone https://github.com/Bigsy/sonos-ace-control.git
cd sonos-ace-control
sh build.sh
open '.build/Ace Control.app'
```

The build targets the current Mac's architecture and macOS 13 or later, runs
protocol parsing checks, and signs the app. Set `ACE_ARCHS=universal` to build
both Apple silicon and Intel slices. It uses an available Apple Development
identity so privacy approvals can persist across rebuilds. Set
`ACE_SIGNING_IDENTITY` to choose another identity. Without one, the build falls
back to ad-hoc signing and macOS may ask for permission after updates.

Maintainers with a Developer ID Application certificate can run
`sh tools/package_release.sh` to create a signed universal ZIP in
`.build/release/`. Set `ACE_NOTARY_PROFILE` to a saved `notarytool` Keychain
profile to notarize and staple the app before packaging.

Allow Bluetooth access, select the headphones, and connect. Tick **Auto-connect
to last headphones** in the window or menu bar to reconnect to that device on
future launches and after an unexpected disconnection. Connect manually once
before using auto-connect; a manual **Disconnect** turns it off. Close the
Sonos phone app if it is holding the control connection. No Android phone, ADB
connection or captured authentication token is needed to use the controller.

Click the menu bar icon to access settings. Battery is refreshed every minute.
Choose **Quit Ace Control** to end the app; closing its window leaves it running.
Recorded shortcuts work anywhere on the Mac while Ace Control is running. They
require Command, Option or Control, or a function key, to avoid intercepting ordinary typing. The
Shortcuts tab can limit them to Ace Control instead; selections and key
combinations are saved between launches. In the Shortcuts tab, choose the noise
modes that its shortcut cycles through; all three are selected by default. A
shortcut does nothing until the headphones are connected and their current
setting has been read.

## Current limitations

This is an interoperability prototype, not an official Sonos application.
Setting availability depends on the headphones and firmware. USB audio can
coexist with BLE control, but enabling sidetone over USB has not been achieved.
Firmware updates, account setup, TV Audio Swap setup and TrueCinema calibration
remain outside this project's scope.

Device authentication verifies certificate/message integrity and the device's
challenge signature, but does not yet validate the manufacturer's certificate
chain. Authentication tokens are kept in memory and are not logged or persisted.

The `tools/` directory contains inspection utilities. App logs are stored at
`~/Library/Logs/Ace Control.log`.

## Licence

MIT. See [LICENSE](LICENSE).
