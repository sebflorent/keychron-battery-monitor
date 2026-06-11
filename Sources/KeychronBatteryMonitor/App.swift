import SwiftUI

@main
struct KeychronBatteryMonitorApp: App {

    @StateObject private var bluetoothManager = BluetoothManager.shared
    @StateObject private var notificationManager = NotificationManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(bluetoothManager)
        } label: {
            MenuBarLabel()
                .environmentObject(bluetoothManager)
        }

        Settings {
            PreferencesView()
                .environmentObject(bluetoothManager)
                .environmentObject(notificationManager)
        }
    }
}
