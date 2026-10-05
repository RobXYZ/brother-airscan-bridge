# brother-airscan-bridge

Makes a Brother ADS-1100W document scanner appear to macOS as an AirScan scanner, so Image Capture, Preview and other apps can use it through Apple's own built-in scanner driver.

The ADS-1100W only speaks Brother's proprietary network scan protocol. This is a small background service that sits in between: it advertises an AirScan (eSCL) scanner on your network and translates each scan request into Brother's protocol.

```
Image Capture / Preview ──AirScan (eSCL, HTTP)──▶ brother-airscan-bridge ──Brother protocol (TCP 54921)──▶ scanner
```

No Brother software, no Rosetta, and no third-party scanner plug-in is involved.

> **AI disclaimer.** This project was written largely with AI assistance (Claude), to get a quick working solution for my own scanner and my own use. It has been tested only on my setup, as described under [Tested](#tested), and has not had a thorough human code review. It is shared in case it is useful to someone else, with no warranty or promise of support. Please read the code and judge for yourself before relying on it.

## Requirements

- macOS 13 or later (developed and tested on macOS 26.5, Apple silicon).
- Xcode or the Xcode command-line tools (`xcode-select --install`).
- The scanner on the same network as the Mac.

## Install

```bash
scripts/install.sh
```

This builds the bridge and installs it as a per-user background service that starts at login. It does not need sudo. It puts three things on your Mac:

| What | Where |
|---|---|
| The program | `~/Library/Application Support/brother-airscan-bridge/brother-airscan-bridge` |
| The service definition | `~/Library/LaunchAgents/local.brother-airscan-bridge.plist` |
| The log | `~/Library/Logs/brother-airscan-bridge.log` |

After a few seconds **Brother ADS-1100W (AirScan)** appears in Image Capture and in Preview's File ▸ Import from Scanner. Choose *Document Feeder* as the source.

The scanner is found automatically. To pin it to an address instead, or change the advertised name or port, pass the bridge's options through the installer:

```bash
scripts/install.sh --host 192.168.1.50 --name "Office scanner"
```

macOS may ask whether the bridge can find devices on your local network; it needs that to reach the scanner.

## Uninstall

```bash
scripts/uninstall.sh
```

Stops the service and removes the three items above.

## Running it by hand

```bash
swift build -c release
.build/release/brother-airscan-bridge
```

| Option | Meaning |
|---|---|
| `--host ADDRESS` | Scanner address. Found over Bonjour if omitted. |
| `--port N` | Port to listen on. Chosen by the system if omitted; clients learn it from Bonjour. |
| `--name NAME` | Name to advertise. Defaults to "Brother ADS-1100W (AirScan)". |
| `--discover` | Look for a supported scanner, print where it is, and exit. |

It logs to standard error and runs until interrupted.

## What it supports

- Colour, greyscale and black & white.
- 100, 150, 200, 300, 400 and 600 dpi.
- Single- and double-sided scanning from the feeder, up to 8.5" × 14".
- Pages are handed to the app as each one finishes, while the next sheet feeds.
- Cancelling stops the scanner.

Pages are delivered as JPEG. Colour arrives from the scanner as JPEG; greyscale and black & white arrive losslessly (run-length coded) and are encoded to JPEG at high quality by the bridge.

Not supported: USB, models other than the ADS-1100W, and the scanner's own scan button.

## Known behaviour

- **Empty feeder.** The bridge always reports the feeder as loaded, because asking the scanner takes a couple of seconds and a connection to its scan port, and apps poll constantly. If the feeder turns out to be empty the scan ends within about two seconds with no pages.
- **The bridge is visible on your local network.** Any device on the same network can see the advertised scanner and start a scan. Request sizes and connection counts are limited, but there is no authentication, as is usual for AirScan devices.
- **Wide pages.** The scanner's sensor is 212 mm wide, slightly narrower than US Letter (216 mm). Letter and Legal scans are padded with a thin white strip on the right.
- **Black & white from Apple's apps.** macOS asks the bridge for greyscale and makes the two-tone image itself; the bridge's own 1-bit mode is only used by other AirScan clients.

## Tested

On an ADS-1100W over Wi-Fi with macOS 26.5.1.

Through ImageCaptureCore (the interface Image Capture and Preview use), via Apple's AirScan driver: colour, greyscale and black & white at 150–300 dpi; double-sided; empty feeder.

Against the bridge's AirScan interface directly: 1-bit black & white, and cancel followed by a fresh scan.

As the installed background service, from a scanning app: 600 dpi colour, double-sided.

Not exercised: 400 dpi and paper sizes other than A4.

## Troubleshooting

- **Log.** `~/Library/Logs/brother-airscan-bridge.log` records each request from macOS, each job with its settings, and how it ended.
- **The scanner isn't listed.** Check the service is running (`launchctl print gui/$(id -u)/local.brother-airscan-bridge`) and that it is advertised (`dns-sd -B _uscan._tcp local.`).
- **Scans end immediately with no pages.** Either the feeder is empty or the bridge can't reach the scanner; the log says which. `brother-airscan-bridge --discover` shows whether the scanner can be found.
- **"could not connect to the scanner".** Another program may be using it — the scanner accepts one client at a time. Otherwise check System Settings ▸ Privacy & Security ▸ Local Network.

## Development

```bash
swift build
swift test
```

| Path | What it is |
|---|---|
| `Sources/CBrotherScan/` | Brother's network scan protocol as a small C library |
| `Sources/BridgeCore/ScannerModel.swift` | Everything model-specific: resolutions, scan area, feeder, duplex |
| `Sources/BridgeCore/BrotherDevice.swift` | Swift wrapper around the protocol library |
| `Sources/BridgeCore/ESCLServer.swift` | The AirScan endpoints and job handling |
| `Sources/BridgeCore/ScanSettings.swift` | Parsing scan requests and working out what to ask the scanner for |
| `Sources/BridgeCore/Imaging.swift` | Turning scanner data into the JPEGs clients receive |
| `Sources/BridgeCore/ScannerLocator.swift` | Finding the scanner over Bonjour |
| `Sources/BridgeCore/HTTPServer.swift` | A small HTTP server with Bonjour advertisement |
| `scripts/` | Install and uninstall |

Supporting another Brother model that speaks the same protocol should mostly be a matter of adding a profile to `ScannerModel.swift` — and testing on that hardware, since models differ in details such as whether they accept an open-ended page length.

## Acknowledgements

[brother-escl](https://github.com/grk/brother-escl) by Grzesiek Kolodziejczyk does the same thing for Brother multifunction printers and showed how little macOS's AirScan client needs from a server. The HTTP server here is adapted from it; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Not affiliated with or endorsed by Brother Industries, Ltd.

## Licence

[MIT](LICENSE). Code adapted from brother-escl remains under its own MIT licence; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
