import CoreBluetooth
import Foundation

/// Reads standard BLE Battery Service (0x180F / 0x2A19) for accessories connected over BLE.
/// Complements HID-based reading for devices like Logitech MX (Bluetooth Low Energy).
final class BLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private weak var owner: BluetoothManager?
    private var central: CBCentralManager!
    private var targetNamesLowercased: Set<String> = []
    private var scanStopTimer: Timer?
    private var widenScanTimer: Timer?
    /// Peripherals we connected from a scan — safe to cancel after a read.
    private var scanInitiatedConnection: Set<UUID> = []

    init(owner: BluetoothManager) {
        self.owner = owner
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func refreshIfNeeded(connectedDeviceNames: [String]) {
        targetNamesLowercased = Set(connectedDeviceNames.map { $0.lowercased() })
        guard central.state == .poweredOn else { return }
        attemptRetrieveAndRead()
        startScanning()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        attemptRetrieveAndRead()
        startScanning()
    }

    private func attemptRetrieveAndRead() {
        let batteryUUID = CBUUID(string: "180F")
        for peripheral in central.retrieveConnectedPeripherals(withServices: [batteryUUID]) {
            guard matchesTarget(peripheral, advertisementLocalName: nil) else { continue }
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([batteryUUID])
            } else {
                central.connect(peripheral, options: nil)
            }
        }
    }

    private func startScanning() {
        scanStopTimer?.invalidate()
        widenScanTimer?.invalidate()
        central.stopScan()
        central.scanForPeripherals(
            withServices: [CBUUID(string: "180F")],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        widenScanTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.central.stopScan()
            self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        scanStopTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.central.stopScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard matchesTarget(peripheral, advertisementLocalName: localName) else { return }
        peripheral.delegate = self
        switch peripheral.state {
        case .connected:
            peripheral.discoverServices([CBUUID(string: "180F")])
        case .disconnected:
            scanInitiatedConnection.insert(peripheral.identifier)
            central.connect(peripheral, options: nil)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: "180F")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        scanInitiatedConnection.remove(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        scanInitiatedConnection.remove(peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        peripheral.services?
            .filter { $0.uuid == CBUUID(string: "180F") }
            .forEach { peripheral.discoverCharacteristics([CBUUID(string: "2A19")], for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        service.characteristics?
            .filter { $0.uuid == CBUUID(string: "2A19") }
            .forEach { peripheral.readValue(for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer { maybeDisconnectAfterRead(peripheral) }
        guard error == nil,
              characteristic.uuid == CBUUID(string: "2A19"),
              let data = characteristic.value,
              let byte = data.first else { return }
        let level = Int(byte)
        guard level >= 0, level <= 100 else { return }
        let name = peripheral.name ?? ""
        owner?.storeBLEBattery(level: level, peripheralName: name)
    }

    private func maybeDisconnectAfterRead(_ peripheral: CBPeripheral) {
        guard scanInitiatedConnection.contains(peripheral.identifier) else { return }
        scanInitiatedConnection.remove(peripheral.identifier)
        central.cancelPeripheralConnection(peripheral)
    }

    private func matchesTarget(_ peripheral: CBPeripheral, advertisementLocalName: String?) -> Bool {
        var names: [String] = []
        if let n = peripheral.name, !n.isEmpty { names.append(n.lowercased()) }
        if let a = advertisementLocalName, !a.isEmpty { names.append(a.lowercased()) }
        guard !names.isEmpty else { return false }
        for t in targetNamesLowercased {
            for n in names {
                if n == t || n.contains(t) || t.contains(n) { return true }
            }
        }
        return false
    }
}
