import Foundation
import IOBluetooth
import IOKit
import IOKit.hid

// MARK: - Models

struct BluetoothDevice: Identifiable, Equatable {
    let id: String          // MAC address (e.g. "dc-2c-26-fd-2a-22")
    let name: String
    let batteryLevel: Int?  // 0-100, nil until first HID report received
    let isConnected: Bool
    let lastUpdated: Date
    var customName: String?

    var displayName: String { customName ?? name }

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
}

// MARK: - BluetoothManager

final class BluetoothManager: ObservableObject {

    static let shared = BluetoothManager()

    @Published var devices: [BluetoothDevice] = []
    @Published var lastRefresh: Date?
    /// Karabiner Elements (DriverKit) holds exclusive HID access — our HID battery path cannot see the Keychron.
    @Published var karabinerMayBlockBattery: Bool = false

    private var bleReader: BLEBatteryReader!
    private var lastBLEScan: Date = .distantPast

    var refreshInterval: TimeInterval {
        get { UserDefaults.standard.double(forKey: "refreshInterval").nonZero ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "refreshInterval") }
    }

    // Battery cache: keys are normalised MAC addresses, or "name:<lowercased>" for BLE-only reads (e.g. MX Master).
    private var batteryCache: [String: CachedBattery] = [:]
    // Maps raw IOHIDDeviceRef pointer → normalised MAC for use inside C callbacks
    private var hidDeviceMap: [UInt: String] = [:]

    private var hidManager: IOHIDManager?
    private var timer: Timer?
    private var customNames: [String: String] = [:]

    private struct CachedBattery: Codable {
        var level: Int
        var date: Date
    }

    private init() {
        bleReader = BLEBatteryReader(owner: self)
        loadCustomNames()
        loadBatteryCache()
        setupHIDListener()
        refreshDeviceList()
        startTimer()
    }

    // MARK: - Timer / Device List

    func startMonitoring() {
        startTimer()
        refreshDeviceList()
    }

    func restartMonitoring() {
        timer?.invalidate()
        startTimer()
    }

    @objc func refresh() {
        refreshDeviceList()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshDeviceList()
        }
    }

    private func refreshDeviceList() {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }

        let updated: [BluetoothDevice] = paired
            .filter { $0.isConnected() }
            .compactMap { device -> BluetoothDevice? in
                guard let address = device.addressString, let name = device.name else { return nil }
                let macKey = normalise(address)
                let nameKey = "name:\(name.lowercased())"
                let cached = batteryCache[macKey] ?? batteryCache[nameKey]
                let battery = cached?.level
                return BluetoothDevice(
                    id: address,
                    name: name,
                    batteryLevel: battery,
                    isConnected: true,
                    lastUpdated: cached?.date ?? Date(),
                    customName: customNames[address]
                )
            }

        DispatchQueue.main.async {
            self.devices = updated
            self.lastRefresh = Date()
            BatteryHistoryStore.shared.record(devices: updated)
            NotificationManager.shared.checkThresholds(devices: updated)
        }

        let missingBatteryNames = updated.filter { $0.batteryLevel == nil }.map(\.name)
        if !missingBatteryNames.isEmpty, Date().timeIntervalSince(lastBLEScan) > 45 {
            lastBLEScan = Date()
            DispatchQueue.main.async {
                self.bleReader.refreshIfNeeded(connectedDeviceNames: missingBatteryNames)
            }
        }
    }

    /// Called from `BLEBatteryReader` when GATT Battery Level is read (BLE accessories).
    func storeBLEBattery(level: Int, peripheralName: String) {
        let nameKey = "name:\(peripheralName.lowercased())"
        batteryCache[nameKey] = CachedBattery(level: level, date: Date())
        saveBatteryCache()
        refreshDeviceList()
    }

    // MARK: - HID Listener (event-driven battery reading)
    //
    // The Keychron K2 sends HID Report ID 3 (Usage Page 0x06 / Battery Strength)
    // once when it connects, then whenever battery changes.
    // We listen persistently on the main run loop so we never miss a report.

    private func setupHIDListener() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        hidManager = manager
        buildDeviceMap(manager)
        detectKarabiner(in: manager)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Keep map current as devices connect / disconnect
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            let mgr = Unmanaged<BluetoothManager>.fromOpaque(ctx).takeUnretainedValue()
            if let hm = mgr.hidManager {
                mgr.buildDeviceMap(hm)
                mgr.detectKarabiner(in: hm)
            }
        }, selfPtr)

        // Listen for Report ID 3 = battery strength (0–100) — Keychron K2 firmware over Bluetooth Classic HID
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, sender, _, reportID, report, reportLen in
            guard reportID == 3, reportLen >= 1, let ctx, let sender else { return }
            let level = Int(report[0])
            guard level >= 0, level <= 100 else { return }

            let self_ = Unmanaged<BluetoothManager>.fromOpaque(ctx).takeUnretainedValue()
            let senderKey = UInt(bitPattern: sender)

            DispatchQueue.main.async {
                if let serial = self_.hidDeviceMap[senderKey] {
                    self_.storeBattery(level, forNormalisedKey: serial)
                }
            }
        }, selfPtr)
    }

    private func detectKarabiner(in manager: IOHIDManager) {
        guard let cfDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        let found = cfDevices.contains { device in
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            return product.range(of: "Karabiner", options: .caseInsensitive) != nil
        }
        DispatchQueue.main.async {
            self.karabinerMayBlockBattery = found
        }
    }

    private func buildDeviceMap(_ manager: IOHIDManager) {
        guard let cfDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for device in cfDevices {
            guard let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                  transport.lowercased().contains("bluetooth"),
                  let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
                  !serial.isEmpty else { continue }

            let ptr = UInt(bitPattern: Unmanaged.passUnretained(device as AnyObject).toOpaque())
            hidDeviceMap[ptr] = normalise(serial)
        }
    }

    private func storeBattery(_ level: Int, forNormalisedKey key: String) {
        batteryCache[key] = CachedBattery(level: level, date: Date())
        saveBatteryCache()
        refreshDeviceList()
    }

    // MARK: - Battery Cache Persistence

    private var cacheURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KeychronBatteryMonitor/battery_cache.json")
    }

    private func saveBatteryCache() {
        guard let data = try? JSONEncoder().encode(batteryCache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadBatteryCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedBattery].self, from: data) else { return }
        // Discard readings older than 24h (stale after a full recharge cycle)
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        batteryCache = decoded.filter { $0.value.date > cutoff }
    }

    // MARK: - Custom Names

    func setCustomName(_ name: String?, for deviceID: String) {
        customNames[deviceID] = name?.isEmpty == false ? name : nil
        saveCustomNames()
        refreshDeviceList()
    }

    private func saveCustomNames() {
        UserDefaults.standard.set(customNames, forKey: "deviceCustomNames")
    }

    private func loadCustomNames() {
        customNames = UserDefaults.standard.dictionary(forKey: "deviceCustomNames") as? [String: String] ?? [:]
    }

    // MARK: - Computed

    var criticalDevice: BluetoothDevice? {
        devices
            .filter { $0.batteryLevel != nil }
            .min(by: { ($0.batteryLevel ?? 100) < ($1.batteryLevel ?? 100) })
    }

    // MARK: - Helpers

    func normalise(_ address: String) -> String {
        address.lowercased()
            .replacingOccurrences(of: "-", with: ":")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: -

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
