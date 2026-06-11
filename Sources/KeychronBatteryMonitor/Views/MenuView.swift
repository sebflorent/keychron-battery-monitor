import SwiftUI

struct MenuView: View {

    @EnvironmentObject var bluetoothManager: BluetoothManager
    @State private var showHistory = false
    @State private var showPreferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Keychron Battery Monitor")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                Spacer()
            }

            Divider()

            if bluetoothManager.karabinerMayBlockBattery {
                karabinerNotice
                Divider()
            }

            // Devices
            if bluetoothManager.devices.isEmpty {
                emptyStateView
            } else {
                ForEach(bluetoothManager.devices) { device in
                    DeviceRow(device: device)
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Actions
            Button {
                bluetoothManager.refresh()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                    Spacer()
                    if let last = bluetoothManager.lastRefresh {
                        Text(last, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .menuItemStyle()

            Button {
                showHistory = true
            } label: {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    Text("Battery History")
                }
            }
            .menuItemStyle()

            Divider()
                .padding(.vertical, 4)

            Button {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Preferences…")
                }
            }
            .menuItemStyle()

            Button("Quit Keychron Battery Monitor") {
                NSApplication.shared.terminate(nil)
            }
            .menuItemStyle()
            .padding(.bottom, 6)
        }
        .frame(width: 280)
        .sheet(isPresented: $showHistory) {
            BatteryHistoryView()
                .environmentObject(bluetoothManager)
        }
    }

    private var karabinerNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Karabiner Elements detected", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Karabiner’s DriverKit driver takes exclusive HID access. This app cannot read the Keychron’s battery over HID while Karabiner is active. Options: disable Karabiner temporarily, exclude the Keychron device in Karabiner, or uninstall the virtual HID driver to restore battery reports.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "keyboard.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Bluetooth keyboards found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Connect a Bluetooth keyboard to see its battery level.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}

// MARK: - Device Row

struct DeviceRow: View {

    let device: BluetoothDevice

    @StateObject private var historyStore = BatteryHistoryStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.name.lowercased().contains("mouse") || device.name.lowercased().contains("mx master") ? "computermouse" : "keyboard")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .medium))

                if let rate = historyStore.dischargeRate(for: device.id) {
                    Text(rateText(rate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let level = device.batteryLevel {
                HStack(spacing: 4) {
                    Image(systemName: device.batteryIcon)
                        .foregroundStyle(batteryColor(for: level))
                    Text("\(level)%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(batteryColor(for: level))
                }
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func batteryColor(for level: Int) -> Color {
        switch level {
        case 20...: return .green
        case 10..<20: return .yellow
        default: return .red
        }
    }

    private func rateText(_ rate: Double) -> String {
        if rate < -0.5 {
            return String(format: "%.1f%%/hr · discharging", abs(rate))
        } else if rate > 0.5 {
            return "charging"
        } else {
            return "idle"
        }
    }
}

// MARK: - Button Style Helper

private struct MenuItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
    }
}

extension View {
    func menuItemStyle() -> some View {
        buttonStyle(MenuItemButtonStyle())
    }
}
