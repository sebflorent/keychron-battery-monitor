import SwiftUI

struct MenuBarLabel: View {

    @EnvironmentObject var bluetoothManager: BluetoothManager

    var body: some View {
        Group {
            if let device = bluetoothManager.criticalDevice,
               let level = device.batteryLevel {
                HStack(spacing: 3) {
                    Image(systemName: batteryIcon(for: level))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(batteryForeground(for: level), Color.primary)
                    Text("\(level)%")
                        .font(.system(size: 12, weight: .medium))
                }
            } else {
                Image(systemName: "keyboard.badge.ellipsis")
            }
        }
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private func batteryForeground(for level: Int) -> Color {
        switch level {
        case 20...: return .green
        case 10..<20: return .yellow
        default: return .red
        }
    }
}
