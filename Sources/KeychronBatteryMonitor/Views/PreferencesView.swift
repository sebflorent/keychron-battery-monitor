import SwiftUI
import ServiceManagement

struct PreferencesView: View {

    @EnvironmentObject var bluetoothManager: BluetoothManager
    @EnvironmentObject var notificationManager: NotificationManager

    @State private var lowThreshold: Double = 20
    @State private var criticalThreshold: Double = 10
    @State private var refreshIntervalIndex: Int = 1
    @State private var launchAtLogin: Bool = false
    @State private var editingDeviceID: String? = nil
    @State private var deviceNickname: String = ""

    private let refreshOptions: [(label: String, value: TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("5 minutes", 300),
        ("10 minutes", 600)
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            devicesTab
                .tabItem { Label("Devices", systemImage: "keyboard") }

            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 400, height: 320)
        .onAppear(perform: loadSettings)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Poll interval", selection: $refreshIntervalIndex) {
                    ForEach(refreshOptions.indices, id: \.self) { i in
                        Text(refreshOptions[i].label).tag(i)
                    }
                }
                .onChange(of: refreshIntervalIndex) { idx in
                    bluetoothManager.refreshInterval = refreshOptions[idx].value
                    bluetoothManager.restartMonitoring()
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        setLaunchAtLogin(enabled)
                    }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    // MARK: - Devices Tab

    private var devicesTab: some View {
        Form {
            Section("Connected Devices") {
                if bluetoothManager.devices.isEmpty {
                    Text("No devices connected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bluetoothManager.devices) { device in
                        deviceRow(for: device)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func deviceRow(for device: BluetoothDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(device.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") {
                editingDeviceID = device.id
                deviceNickname = device.customName ?? ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .sheet(isPresented: Binding(
            get: { editingDeviceID == device.id },
            set: { if !$0 { editingDeviceID = nil } }
        )) {
            renameSheet(for: device)
        }
    }

    private func renameSheet(for device: BluetoothDevice) -> some View {
        VStack(spacing: 16) {
            Text("Rename Device")
                .font(.headline)
            TextField("Custom name (leave blank to reset)", text: $deviceNickname)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Button("Cancel") { editingDeviceID = nil }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Save") {
                    bluetoothManager.setCustomName(deviceNickname, for: device.id)
                    editingDeviceID = nil
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    // MARK: - Notifications Tab

    private var notificationsTab: some View {
        Form {
            Section("Alerts") {
                if !notificationManager.isAuthorized {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Notifications are not authorized.")
                        Spacer()
                        Button("Enable") {
                            notificationManager.requestPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Toggle("Enable low battery alerts", isOn: Binding(
                    get: { notificationManager.notificationsEnabled },
                    set: { notificationManager.notificationsEnabled = $0 }
                ))
                .disabled(!notificationManager.isAuthorized)
            }

            Section("Thresholds") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Low battery at \(Int(lowThreshold))%")
                    Slider(value: $lowThreshold, in: 5...50, step: 5)
                        .onChange(of: lowThreshold) { v in
                            notificationManager.lowBatteryThreshold = Int(v)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Critical battery at \(Int(criticalThreshold))%")
                    Slider(value: $criticalThreshold, in: 1...20, step: 1)
                        .onChange(of: criticalThreshold) { v in
                            notificationManager.criticalBatteryThreshold = Int(v)
                        }
                }
            }
            .disabled(!notificationManager.notificationsEnabled || !notificationManager.isAuthorized)
        }
        .formStyle(.grouped)
        .padding(8)
    }

    // MARK: - Load / Save

    private func loadSettings() {
        lowThreshold = Double(notificationManager.lowBatteryThreshold)
        criticalThreshold = Double(notificationManager.criticalBatteryThreshold)
        let interval = bluetoothManager.refreshInterval
        refreshIntervalIndex = refreshOptions.firstIndex(where: { $0.value == interval }) ?? 1
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[PreferencesView] Launch at login error: \(error)")
        }
    }
}
