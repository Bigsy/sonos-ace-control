# Sonos Ace Control

An independent macOS controller for Sonos headphones over Bluetooth LE, tested
with Sonos Ace Ultra. Requires macOS 13 or later.

## Screenshots

| | |
| :---: | :---: |
| **Sound**<br><img width="300" alt="Sound settings" src="https://github.com/user-attachments/assets/ee3c6a3e-576d-40ab-af83-055f6e7eb8bd" /> | **Audio options**<br><img width="300" alt="Audio options settings" src="screenshots/audio-options.png" /> |
| **Controls**<br><img width="300" alt="Controls settings" src="screenshots/controls.png" /> | **Power**<br><img width="300" alt="Power settings" src="screenshots/power.png" /> |
| **Voice**<br><img width="300" alt="Voice settings" src="screenshots/voice.png" /> | **Shortcuts**<br><img width="300" alt="Shortcuts settings" src="screenshots/shortcuts.png" /> |

## Features

- Menu bar controls and headphone battery level.
- Noise control, sidetone, equalizer, and other audio, power, voice, and device settings.
- Optional auto-connect to the last connected headphones.
- Global keyboard shortcuts for selected controls, with a choice of which noise
  modes the shortcut cycles through.
- Settings changes verified by reading them back from the headphones.

## Install

Download the ZIP from [Releases](https://github.com/Bigsy/sonos-ace-control/releases),
unzip it, and move **Ace Control.app** to Applications. The release supports Apple
silicon and Intel Macs. Allow Bluetooth access when macOS asks.

Releases are Developer ID-signed but not notarized. If macOS blocks the first
launch, try opening the app, then use **System Settings → Privacy & Security →
Open Anyway** as described by [Apple](https://support.apple.com/en-gb/102445).

## Use

Select your headphones and connect. You can then enable **Auto-connect to last
headphones** in the window or menu bar. If connection fails, close the Sonos
phone app and try again.

The menu bar icon provides quick access to settings. Tick **Shortcut** beside a
control to add it to the Shortcuts tab, where you can record a key combination
and choose which noise modes to cycle through. Shortcuts work while the app is
running, even when its window is closed.

## Build from source

Install Xcode or its Command Line Tools (`xcode-select --install`), then run:

```sh
git clone https://github.com/Bigsy/sonos-ace-control.git
cd sonos-ace-control
sh build.sh
open '.build/Ace Control.app'
```

No third-party dependencies are required. For a universal build, use
`ACE_ARCHS=universal sh build.sh`. The script uses an available Apple Development
certificate; without one, ad-hoc signing may cause repeated Bluetooth permission
prompts. Maintainers can use `sh tools/package_release.sh` to create a signed
universal ZIP, and set `ACE_NOTARY_PROFILE` to notarize it.

## Limitations

This is an unofficial interoperability project. Settings depend on headphone
firmware. USB audio can coexist with Bluetooth control, but sidetone over USB
has not been achieved. Firmware updates, account setup, TV Audio Swap, and
TrueCinema calibration are outside this project's scope.

Device authentication checks message integrity and the device challenge, but
does not yet validate the manufacturer's certificate chain. App logs are at
`~/Library/Logs/Ace Control.log`.

## Licence

MIT. See [LICENSE](LICENSE).
