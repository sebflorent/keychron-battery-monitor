import Foundation
import IOBluetooth
import IOKit
import IOKit.hid

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

    // MARK: - Device Discovery

    private func readBluetoothDevices() -> [BluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        // Build a battery map from IOKit HID layer (one pass for all devices)
        let batteryMap = readAllHIDBatteryLevels()

        return paired
            .filter { $0.isConnected() }
            .compactMap { device -> BluetoothDevice? in
                guard let address = device.addressString,
                      let name = device.name else { return nil }

                let battery = batteryMap[normalizeAddress(address)]

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

    // MARK: - IOKit HID Battery Reading

    /// Enumerates all connected IOKit HID devices via Bluetooth and returns a map of
    /// normalised MAC address → battery percentage.
    private func readAllHIDBatteryLevels() -> [String: Int] {
        var result: [String: Int] = [:]

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)  // match all HID devices

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return result
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let cfDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return result
        }

        for hidDevice in cfDevices {
            // Only Bluetooth devices
            guard let transport = IOHIDDeviceGetProperty(hidDevice, kIOHIDTransportKey as CFString) as? String,
                  transport.lowercased().contains("bluetooth") else { continue }

            // Try all known battery property keys
            let level = batteryPercent(from: hidDevice)
            guard let level else { continue }

            // Match address: serial number on BT keyboards is typically the MAC address
            let serial = (IOHIDDeviceGetProperty(hidDevice, kIOHIDSerialNumberKey as CFString) as? String) ?? ""
            let product = (IOHIDDeviceGetProperty(hidDevice, kIOHIDProductKey as CFString) as? String) ?? ""

            let key = normalizeAddress(serial)
            if !key.isEmpty {
                result[key] = level
            } else if !product.isEmpty {
                // Fallback: store by product name for later matching
                result["name:\(product.lowercased())"] = level
            }
        }

        return result
    }

    private func batteryPercent(from device: IOHIDDevice) -> Int? {
        // Keys used by different keyboard firmware implementations
        let keys = [
            "BatteryPercent",
            "Battery Level",
            "BatteryLevel"
        ]
        for key in keys {
            if let value = IOHIDDeviceGetProperty(device, key as CFString) as? Int,
               value >= 0, value <= 100 {
                return value
            }
        }

        // Some devices report via IORegistry node property
        let serviceEntry = IOHIDDeviceGetService(device)
        defer { IOObjectRelease(serviceEntry) }

        if serviceEntry != IO_OBJECT_NULL {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(serviceEntry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                for key in keys {
                    if let value = dict[key] as? Int, value >= 0, value <= 100 {
                        return value
                    }
                }
            }
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

    // MARK: - Helpers

    private func normalizeAddress(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "-", with: ":")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
