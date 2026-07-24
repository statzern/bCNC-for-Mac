# bCNC macOS DMG Builder

Packages **[bCNC](https://github.com/vlachoudis/bCNC)** (CNC G-code sender) into a self-contained macOS `.app` with full **OpenCV camera support** and all dependencies bundled. No Python installation required on the end-user machine.

## What's included

| Component | Version | Purpose |
|-----------|---------|---------|
| bCNC | 0.9.16 | CNC G-code sender / controller |
| opencv-python-headless | 5.0.0.93 | Camera capture via AVFoundation |
| numpy | 2.4.6 | Numerical operations (opencv-python 5.x requires numpy ≥2) |
| Pillow | ≥11.0 | Image processing |
| pyserial | ≥3.5 | USB/serial comms with CNC machine |
| svgelements | ≥1.9,<2.0 | SVG import |
| shxparser | ≥0.0.2 | SHX font support |
| tkinter-gl | ≥1.1 | OpenGL canvas |
| pyinstaller | 6.21.0 | App bundling |

## Prerequisites

Install these once on your Mac:

```bash
# Xcode Command Line Tools
xcode-select --install

# Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Python 3.13 with tkinter + packaging tool
brew install python@3.13 python-tk@3.13 create-dmg
```

> **Minimum macOS version:** opencv-python-headless 5.x ships wheels for macOS 14 (Sonoma) or newer on Intel Macs, and macOS 13 (Ventura) or newer on Apple Silicon. The built `.app` sets `LSMinimumSystemVersion` to match whichever architecture it was built on.

## Build

```bash
git clone https://github.com/YOUR_USERNAME/bcnc-mac-build
cd bcnc-mac-build
chmod +x build_dmg.sh
./build_dmg.sh
```

Output: `bCNC-0.9.16-mac.dmg` in the project root (~150 MB, build takes 2–4 min).

## Install

1. Open `bCNC-0.9.16-mac.dmg`
2. Drag **bCNC.app** → **Applications**
3. **First launch:** right-click → **Open** (bypasses Gatekeeper — required once)
4. Allow camera access when prompted by macOS

## Camera setup

1. Open bCNC → **Tools** tab → **Camera**
2. Set **Camera Index** to `0` (built-in webcam) or `1`, `2`… for USB cameras
3. Click **Open Camera**

The camera runs on a background thread — the UI stays fully responsive while the camera is active.

## USB / Serial drivers

Install the driver for your CNC controller's USB chip if needed:

| Chip | Driver |
|------|--------|
| CP2102 / CP2104 | [Silicon Labs VCP](https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers) |
| CH340 / CH341 | [WCH CH34x](https://www.wch-ic.com/products/CH341.html) |
| FTDI | [FTDI VCP](https://ftdichip.com/drivers/vcp-drivers/) |

After installing, reconnect the controller and look for `/dev/cu.usbserial-*` in bCNC's Port dropdown.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "App is damaged" | `xattr -cr /Applications/bCNC.app` in Terminal |
| Camera not working | System Settings → Privacy & Security → Camera → enable bCNC |
| Serial port missing | Install USB driver above, reconnect |
| Build fails: tkinter | `brew install python-tk@3.11` |
| Build fails: create-dmg | `brew install create-dmg` |

## Distributing (optional notarization)

The default build uses ad-hoc signing. For fully notarized, Gatekeeper-clean distribution (requires [Apple Developer account](https://developer.apple.com/programs/)):

```bash
codesign --deep --force \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements entitlements.plist \
  --options runtime \
  dist/bCNC.app

xcrun notarytool submit bCNC-0.9.16-mac.dmg \
  --apple-id you@example.com --team-id TEAMID \
  --password "@keychain:AC_PASSWORD" --wait

xcrun stapler staple bCNC-0.9.16-mac.dmg
```

## Credits

bCNC is by [Vasilis Vlachoudis](https://github.com/vlachoudis/bCNC). This repo just packages it for macOS.
