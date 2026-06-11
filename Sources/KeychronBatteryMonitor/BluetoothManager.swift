import Foundation
import IOBluetooth
import Combine

// MARK: - Models

struct BluetoothDevice: Identifiable, Equatable {
    let id: String          // MAC address
    let name: String
    let batteryLevel: Int?  // 0-100, nil if not reported
    let isConnected: Bool
    let lastUpdated: Date
    var customName: String?

    var displayName: String {
        customName ?? name
    }

    var batteryIcon: String {
        guard let level = batteryLevel else { return "battery.0" }
        switch level {
        case 75...: return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        case 10..<25: return "battery.25"
        default: return "battery.0"
        }
    }

    var batteryColor: String {
        guard let level = batteryLevel else { return "secondary" }
        switch level {
        case 20...: return "green"
        case 10..<20: return "yellow"
        default: return "red"
        }
    }
}

// MARK: - BluetoothManager

final class BluetoothManager: ObservableObject {

    static let shared = BluetoothManager()

    @Published var devices: [BluetoothDevice] = []
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?

    private var timer: Timer?
    private var customNames: [String: String] = [:]

    var refreshInterval: TimeInterval {
        get { UserDefaults.standard.double(forKey: "refreshInterval").nonZero ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "refreshInterval") }
    }

    private init() {
        loadCustomNames()
        startMonitoring()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func restartMonitoring() {
        startMonitoring()
    }

    @objc func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let updated = self.readBluetoothDevices()
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.devices = updated
                self.lastRefresh = Date()
                BatteryHistoryStore.shared.record(devices: updated)
                NotificationManager.shared.checkThresholds(devices: updated)
            }
        }
    }

    // MARK: - IOBluetooth

    private func readBluetoothDevices() -> [BluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        return paired
            .filter { $0.isConnected() }
            .compactMap { device -> BluetoothDevice? in
                guard let address = device.addressString,
                      let name = device.name else { return nil }

                let battery = readBatteryLevel(from: device)

                return BluetoothDevice(
                    id: address,
                    name: name,
                    batteryLevel: battery,
                    isConnected: true,
                    lastUpdated: Date(),
                    customName: customNames[address]
                )
            }
    }

    private func readBatteryLevel(from device: IOBluetoothDevice) -> Int? {
        // Primary: IOBluetoothDevice.batteryLevel (available on macOS 10.15+)
        // Returns 0-100, or -1 if not available / device doesn't report battery
        let raw = device.value(forKey: "batteryLevel") as? Int
        if let level = raw, level >= 0, level <= 100 {
            return level
        }

        // Fallback: check extraAttributeDictionary which some devices populate
        if let attrs = device.value(forKey: "extraAttributeDictionary") as? [String: Any],
           let level = attrs["BatteryPercent"] as? Int, level >= 0 {
            return level
        }

        return nil
    }

    // MARK: - Custom Names

    func setCustomName(_ name: String?, for deviceID: String) {
        customNames[deviceID] = name?.isEmpty == false ? name : nil
        saveCustomNames()
        if let idx = devices.firstIndex(where: { $0.id == deviceID }) {
            devices[idx] = BluetoothDevice(
                id: devices[idx].id,
                name: devices[idx].name,
                batteryLevel: devices[idx].batteryLevel,
                isConnected: devices[idx].isConnected,
                lastUpdated: devices[idx].lastUpdated,
                customName: customNames[deviceID]
            )
        }
    }

    private func saveCustomNames() {
        UserDefaults.standard.set(customNames, forKey: "deviceCustomNames")
    }

    private func loadCustomNames() {
        customNames = UserDefaults.standard.dictionary(forKey: "deviceCustomNames") as? [String: String] ?? [:]
    }

    // MARK: - Computed

    /// The device with the lowest battery — used for the menu bar icon
    var criticalDevice: BluetoothDevice? {
        devices
            .filter { $0.batteryLevel != nil }
            .min(by: { ($0.batteryLevel ?? 100) < ($1.batteryLevel ?? 100) })
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
