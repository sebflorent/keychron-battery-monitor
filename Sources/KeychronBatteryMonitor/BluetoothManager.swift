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
    private var lastHIDPoll: Date = .distantPast
    private var didInitialHIDPoll = false

    var refreshInterval: TimeInterval {
        get { UserDefaults.standard.double(forKey: "refreshInterval").nonZero ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "refreshInterval") }
    }

    // Battery cache: keys are normalised MAC addresses, or "name:<lowercased>" for BLE-only reads (e.g. MX Master).
    private var batteryCache: [String: CachedBattery] = [:]

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

        // Synchronous HID GetReport poll (Feature/Input) — throttled; also once soon after launch.
        let pairedMacs = Set(updated.map { normalise($0.id) })
        let needsBattery = updated.contains { $0.batteryLevel == nil }
        let throttleOK = Date().timeIntervalSince(lastHIDPoll) > 25
        let forceInitial = needsBattery && !didInitialHIDPoll
        if !pairedMacs.isEmpty, needsBattery, throttleOK || forceInitial {
            if forceInitial { didInitialHIDPoll = true }
            lastHIDPoll = Date()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.pollHIDBatteryReports(pairedMacKeys: pairedMacs)
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
        detectKarabiner(in: manager)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Keep Karabiner detection current as devices connect / disconnect
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            let mgr = Unmanaged<BluetoothManager>.fromOpaque(ctx).takeUnretainedValue()
            if let hm = mgr.hidManager {
                mgr.detectKarabiner(in: hm)
            }
        }, selfPtr)

        // Input reports (interrupt). Keychron K2: report ID 3, first byte = 0…100 (%).
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, sender, _, reportID, report, reportLen in
            guard result == kIOReturnSuccess, reportLen >= 1, let ctx, let sender else { return }
            let self_ = Unmanaged<BluetoothManager>.fromOpaque(ctx).takeUnretainedValue()
            guard let macKey = self_.macKey(fromHIDSender: sender) else { return }

            let level: Int?
            if reportID == 3 {
                level = Int(report[0])
            } else if reportID == 0, reportLen >= 2, report[0] == 3 {
                // Some stacks prepend report ID in the buffer
                level = Int(report[1])
            } else {
                level = nil
            }
            guard let level, level >= 0, level <= 100 else { return }

            DispatchQueue.main.async {
                self_.storeBattery(level, forNormalisedKey: macKey)
            }
        }, selfPtr)
    }

    /// Resolve Bluetooth MAC key from an `IOHIDReportCallback` `sender` (IOHIDDeviceRef).
    private func macKey(fromHIDSender sender: UnsafeMutableRawPointer) -> String? {
        let device: IOHIDDevice = unsafeBitCast(sender, to: IOHIDDevice.self)
        guard let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
              !serial.isEmpty else { return nil }
        return normalise(serial)
    }

    /// Try synchronous GetReport for report ID 3 (Keychron battery strength in descriptor).
    private func pollHIDBatteryReports(pairedMacKeys: Set<String>) {
        guard let manager = hidManager,
              let cfDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }

        for device in cfDevices {
            guard let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                  transport.lowercased().contains("bluetooth"),
                  let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
                  !serial.isEmpty else { continue }

            let macKey = normalise(serial)
            guard pairedMacKeys.contains(macKey) else { continue }

            let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard open == kIOReturnSuccess || open == kIOReturnExclusiveAccess else { continue }
            defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

            for reportType in [kIOHIDReportTypeFeature, kIOHIDReportTypeInput] {
                var buf = [UInt8](repeating: 0, count: 32)
                var len = buf.count
                let gr = IOHIDDeviceGetReport(device, reportType, CFIndex(3), &buf, &len)
                guard gr == kIOReturnSuccess, len >= 1 else { continue }

                let level: Int?
                if len >= 2, buf[0] == 3 {
                    level = Int(buf[1])
                } else {
                    level = Int(buf[0])
                }
                guard let level, level >= 0, level <= 100 else { continue }

                DispatchQueue.main.async { [weak self] in
                    self?.storeBattery(level, forNormalisedKey: macKey)
                }
                break
            }
        }
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
