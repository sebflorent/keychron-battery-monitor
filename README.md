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

After launching, the app lives in your **menu bar**. Click the battery icon to see all connected devices. If a device doesn't report a battery level (returns `—`), it means the device's firmware doesn't expose the HID Battery Service to macOS — this is rare for Keychron keyboards but can happen.

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

Battery level is read directly from macOS's `IOBluetooth.framework` — the same source used by System Settings → Bluetooth. No background daemons, no kernel extensions, no internet access.

Readings are stored locally in `~/Library/Application Support/KeychronBatteryMonitor/battery_history.json` and are never shared.

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
