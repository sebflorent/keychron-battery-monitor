import Foundation
import UserNotifications

final class NotificationManager: ObservableObject {

    static let shared = NotificationManager()

    @Published var isAuthorized = false

    var lowBatteryThreshold: Int {
        get { UserDefaults.standard.integer(forKey: "lowBatteryThreshold").nonZero ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "lowBatteryThreshold") }
    }

    var criticalBatteryThreshold: Int {
        get { UserDefaults.standard.integer(forKey: "criticalBatteryThreshold").nonZero ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "criticalBatteryThreshold") }
    }

    var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }

    // Track last notified level per device to avoid repeated alerts
    private var lastNotifiedLevel: [String: Int] = [:]

    private init() {
        // Defer authorization check — UNUserNotificationCenter requires a live bundle
        // and must not be called during static initialisation
        DispatchQueue.main.async {
            self.checkAuthorization()
        }
    }

    // MARK: - Authorization

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                if granted {
                    self.notificationsEnabled = true
                }
            }
        }
    }

    private func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    // MARK: - Threshold Checks

    func checkThresholds(devices: [BluetoothDevice]) {
        guard notificationsEnabled, isAuthorized else { return }

        for device in devices {
            guard let level = device.batteryLevel else { continue }
            let lastLevel = lastNotifiedLevel[device.id]

            if level <= criticalBatteryThreshold && (lastLevel == nil || lastLevel! > criticalBatteryThreshold) {
                sendNotification(
                    title: "⚠️ \(device.displayName) Battery Critical",
                    body: "Battery is at \(level)%. Charge soon to avoid disconnection.",
                    identifier: "critical-\(device.id)"
                )
                lastNotifiedLevel[device.id] = level
            } else if level <= lowBatteryThreshold && (lastLevel == nil || lastLevel! > lowBatteryThreshold) {
                sendNotification(
                    title: "\(device.displayName) Battery Low",
                    body: "Battery is at \(level)%. Consider charging.",
                    identifier: "low-\(device.id)"
                )
                lastNotifiedLevel[device.id] = level
            } else if level > lowBatteryThreshold {
                // Reset so we notify again next time it drops
                lastNotifiedLevel[device.id] = nil
            }
        }
    }

    // MARK: - Send

    private func sendNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NotificationManager] error: \(error)")
            }
        }
    }
}

// MARK: - Helpers

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
