import SwiftUI
import Charts

struct BatteryHistoryView: View {

    @EnvironmentObject var bluetoothManager: BluetoothManager
    @StateObject private var historyStore = BatteryHistoryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDeviceID: String? = nil
    @State private var selectedRange: TimeRange = .day

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Battery History")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(16)

            Divider()

            if historyStore.readings.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        devicePicker
                        rangePicker
                        chartSection
                        statsSection
                        exportSection
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 520, height: 420)
        .onAppear {
            if selectedDeviceID == nil {
                selectedDeviceID = historyStore.allDeviceIDs().first
            }
        }
    }

    // MARK: - Subviews

    private var devicePicker: some View {
        Picker("Device", selection: $selectedDeviceID) {
            ForEach(historyStore.allDeviceIDs(), id: \.self) { id in
                Text(historyStore.deviceName(for: id)).tag(Optional(id))
            }
        }
        .pickerStyle(.segmented)
    }

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            ForEach(TimeRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    private var chartSection: some View {
        let data = chartData
        return Group {
            if data.isEmpty {
                Text("No data for this period")
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .foregroundStyle(.secondary)
            } else {
                Chart(data) { reading in
                    LineMark(
                        x: .value("Time", reading.timestamp),
                        y: .value("Battery %", reading.level)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", reading.timestamp),
                        y: .value("Battery %", reading.level)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.1))
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .chartXAxis {
                    AxisMarks(preset: .automatic)
                }
                .frame(height: 160)
            }
        }
    }

    private var statsSection: some View {
        let data = chartData
        guard !data.isEmpty else { return AnyView(EmptyView()) }

        let avg = data.map(\.level).reduce(0, +) / max(data.count, 1)
        let min = data.map(\.level).min() ?? 0
        let max = data.map(\.level).max() ?? 0

        return AnyView(
            HStack(spacing: 0) {
                StatCard(title: "Average", value: "\(avg)%")
                Divider()
                StatCard(title: "Minimum", value: "\(min)%")
                Divider()
                StatCard(title: "Maximum", value: "\(max)%")

                if let deviceID = selectedDeviceID,
                   let rate = historyStore.dischargeRate(for: deviceID) {
                    Divider()
                    StatCard(title: "Rate", value: String(format: "%.1f%%/hr", abs(rate)))
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        )
    }

    private var exportSection: some View {
        HStack {
            Spacer()
            Button("Export CSV") {
                exportCSV()
            }
            .buttonStyle(.bordered)

            Button("Clear History") {
                historyStore.clearHistory()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No History Yet")
                .font(.title3.bold())
            Text("Battery readings are recorded every time the app polls. Check back after a few polling cycles.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private var chartData: [BatteryReading] {
        guard let deviceID = selectedDeviceID else { return [] }
        return historyStore
            .readings(for: deviceID, since: selectedRange.startDate)
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func exportCSV() {
        let csv = historyStore.exportCSV()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "battery-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Supporting Types

enum TimeRange: String, CaseIterable, Identifiable {
    case hour = "1h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }
    var label: String { rawValue }

    var startDate: Date {
        switch self {
        case .hour: return Date().addingTimeInterval(-3600)
        case .day: return Date().addingTimeInterval(-86400)
        case .week: return Date().addingTimeInterval(-7 * 86400)
        case .month: return Date().addingTimeInterval(-30 * 86400)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
