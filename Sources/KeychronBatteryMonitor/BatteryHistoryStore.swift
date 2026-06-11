import Foundation

// MARK: - Models

struct BatteryReading: Codable, Identifiable {
    let id: UUID
    let deviceID: String
    let deviceName: String
    let level: Int
    let timestamp: Date

    init(deviceID: String, deviceName: String, level: Int) {
        self.id = UUID()
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.level = level
        self.timestamp = Date()
    }
}

// MARK: - Store

final class BatteryHistoryStore: ObservableObject {

    static let shared = BatteryHistoryStore()

    @Published var readings: [BatteryReading] = []

    private let maxAge: TimeInterval = 30 * 24 * 60 * 60  // 30 days
    private let storageURL: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KeychronBatteryMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        storageURL = appSupport.appendingPathComponent("battery_history.json")
        load()
    }

    // MARK: - Recording

    func record(devices: [BluetoothDevice]) {
        let newReadings = devices.compactMap { device -> BatteryReading? in
            guard let level = device.batteryLevel else { return nil }
            return BatteryReading(deviceID: device.id, deviceName: device.displayName, level: level)
        }

        guard !newReadings.isEmpty else { return }

        readings.append(contentsOf: newReadings)
        pruneOldReadings()
        save()
    }

    // MARK: - Queries

    func readings(for deviceID: String, since date: Date = .distantPast) -> [BatteryReading] {
        readings.filter { $0.deviceID == deviceID && $0.timestamp >= date }
    }

    func allDeviceIDs() -> [String] {
        Array(Set(readings.map(\.deviceID))).sorted()
    }

    func deviceName(for deviceID: String) -> String {
        readings.last(where: { $0.deviceID == deviceID })?.deviceName ?? deviceID
    }

    /// Estimated discharge rate in % per hour (negative = draining, positive = charging)
    func dischargeRate(for deviceID: String) -> Double? {
        let recent = readings(for: deviceID, since: Date().addingTimeInterval(-24 * 3600))
            .sorted { $0.timestamp < $1.timestamp }

        guard recent.count >= 2 else { return nil }

        let first = recent.first!
        let last = recent.last!
        let hours = last.timestamp.timeIntervalSince(first.timestamp) / 3600
        guard hours > 0 else { return nil }

        return Double(last.level - first.level) / hours
    }

    func estimatedHoursRemaining(for device: BluetoothDevice) -> Double? {
        guard let level = device.batteryLevel, level > 0 else { return nil }
        guard let rate = dischargeRate(for: device.id), rate < 0 else { return nil }
        return Double(level) / abs(rate)
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(readings)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[BatteryHistoryStore] save error: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL) else { return }
        readings = (try? JSONDecoder().decode([BatteryReading].self, from: data)) ?? []
        pruneOldReadings()
    }

    private func pruneOldReadings() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        readings = readings.filter { $0.timestamp > cutoff }
    }

    func clearHistory() {
        readings = []
        try? FileManager.default.removeItem(at: storageURL)
    }

    // MARK: - Export

    func exportCSV() -> String {
        let header = "timestamp,device_id,device_name,battery_level\n"
        let formatter = ISO8601DateFormatter()
        let rows = readings
            .sorted { $0.timestamp < $1.timestamp }
            .map { "\(formatter.string(from: $0.timestamp)),\($0.deviceID),\"\($0.deviceName)\",\($0.level)" }
        return header + rows.joined(separator: "\n")
    }
}
