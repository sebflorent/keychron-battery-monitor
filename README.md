# Keychron Battery Monitor

A lightweight macOS menu bar app that monitors the battery level of your Keychron keyboard (and any other Bluetooth keyboard or mouse).

> macOS has no built-in battery indicator for Bluetooth accessories in the menu bar. This app fills that gap.

## Features

- **Menu bar icon** — dynamically shows battery fill level + percentage
- **Low battery alerts** — configurable notification thresholds (default 20% and 10%)
- **Battery history graph** — tracks charge level over time with Swift Charts
- **Discharge rate** — estimates %/hr drain and hours remaining
- **Multi-device** — shows all connected Bluetooth keyboards and mice
- **Device nicknames** — rename any device to something memorable
- **Launch at login** — starts silently at boot
- **CSV export** — download your full battery history

## Compatibility

Works with any Bluetooth keyboard or mouse that reports battery level to macOS, including:

- All Keychron Bluetooth models (K1, K2, K3, K4, K6, K8, K10, Q-series wireless, etc.)
- Logitech MX series, Anne Pro, Royal Kludge, and others
- Any device whose battery appears in **System Settings → Bluetooth**

**Requires macOS 13 Ventura or later.**

### Known limitations

- **Karabiner Elements** (DriverKit virtual HID): if Karabiner’s driver has exclusive access to your Keychron, macOS will not deliver the keyboard’s HID battery report to this app. The menu shows a warning when Karabiner is detected. Workarounds: temporarily quit Karabiner, exclude the Keychron in Karabiner’s configuration, or use the keyboard without the Karabiner virtual device path.
- **Bluetooth Low Energy mice** (e.g. Logitech MX Master 3S on BLE): battery is read via the standard BLE Battery service when macOS exposes it; behaviour depends on the vendor stack.
- **Corporate MDM / Gatekeeper**: unsigned builds may be blocked; use a locally built `.app` or a Developer ID–signed release.

## Install

### Download (recommended)

1. Download the latest `.dmg` from [Releases](https://github.com/your-username/keychron-battery-monitor/releases)
2. Open the DMG and drag **Keychron Battery Monitor** to `/Applications`
3. On first launch: right-click → **Open**, then click Open in the dialog

> If macOS says the app is "damaged", run this once in Terminal:
> ```bash
> xattr -cr /Applications/KeychronBatteryMonitor.app
> ```
> This removes the internet quarantine flag. The app contains no network code and is fully open source.

### Build from source

```bash
git clone https://github.com/your-username/keychron-battery-monitor.git
cd keychron-battery-monitor
make app       # produces .build/KeychronBatteryMonitor.app
make dmg       # produces .build/KeychronBatteryMonitor-<version>.dmg
```

Requirements: Xcode 15+ / Swift 5.9+

## Usage

After launching, the app lives in your **menu bar**. Click the battery icon to see all connected devices. If a device shows `—`, either it does not publish battery data to macOS, or another tool (e.g. Karabiner) is blocking HID access for that device.

### Preferences

Open **Preferences** from the menu bar dropdown:

| Setting | Description |
|---|---|
| Poll interval | How often battery is read (30s – 10min) |
| Low battery threshold | Alert level (default 20%) |
| Critical threshold | Second alert level (default 10%) |
| Device nickname | Custom name per device |
| Launch at login | Auto-start on boot |

## How it works

- **Bluetooth Classic keyboards (Keychron K2, etc.)**: battery comes from **HID Report ID 3** (Battery Strength) when the OS delivers reports from the real HID device. The app listens on the main run loop and caches the last value.
- **Bluetooth Low Energy accessories**: the app uses **CoreBluetooth** to read the standard **Battery Service** (`0x180F`) / **Battery Level** (`0x2A19`) when available (e.g. some mice).
- **Local data**: history is stored in `~/Library/Application Support/KeychronBatteryMonitor/battery_history.json`; battery cache in the same folder. Nothing is sent over the network.

## Contributing

Pull requests are welcome. To get started:

```bash
swift build        # build
swift run          # run in terminal (limited — no menu bar in this mode)
make app && open .build/KeychronBatteryMonitor.app   # run as proper app
```

Please open an issue before submitting a large change.

## License

MIT — see [LICENSE](LICENSE)
