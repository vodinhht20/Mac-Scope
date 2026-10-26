import SwiftUI
import Charts

@MainActor struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var monitor: MonitoringService
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { PageHeader(title: "Your Mac, at a glance", subtitle: "Live activity and measured system information."); Button { Task { await store.scan() } } label: { Label(store.scanning ? "Scanning…" : "Scan Again", systemImage: "arrow.clockwise") }.disabled(store.scanning) }
                if let snapshot = store.snapshot {
                    Surface {
                        HStack(spacing: 22) {
                            Image(systemName: "desktopcomputer").font(.system(size: 52, weight: .light)).foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 7) { Text(snapshot.model).font(.title2.bold()); Text(snapshot.chip); Text(snapshot.fields.first(where: { $0.title.hasPrefix("GPU") })?.value ?? "GPU information unavailable").font(.caption).foregroundColor(.secondary); Text(snapshot.os).font(.caption).foregroundColor(.secondary) }
                            Spacer()
                            VStack(alignment: .trailing) { Label("Local scan", systemImage: "checkmark.shield").foregroundColor(.secondary); Text(snapshot.date, style: .time).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        MetricCard(title: "Processor", icon: "cpu", value: percent(monitor.samples.last?.cpu), subtitle: "Current CPU activity", samples: monitor.samples, key: \.cpu, color: .blue)
                        MetricCard(title: "Memory", icon: "memorychip", value: percent(monitor.samples.last?.memory), subtitle: "Active + wired + compressed / \(DiagnosticLogic.bytes(Int64(snapshot.memory)))", samples: monitor.samples, key: \.memory, color: .purple)
                        MetricCard(title: "Disk activity", icon: "internaldrive", value: rate(monitor.samples.last?.diskRead), subtitle: "Read rate · all exposed block devices", samples: monitor.samples, key: \.diskRead, color: .orange, isPercent: false)
                        MetricCard(title: "Network", icon: "network", value: rate(monitor.samples.last?.received), subtitle: "Receive rate · \(monitor.network)", samples: monitor.samples, key: \.received, color: .teal, isPercent: false)
                    }
                    HStack { Text("Disk write: \(rate(monitor.samples.last?.diskWrite))"); Spacer(); Text("Network sent: \(rate(monitor.samples.last?.sent))") }.font(.caption).foregroundColor(.secondary)
                    LazyVGrid(columns: columns, spacing: 16) {
                        Surface {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Label("Storage", systemImage: "internaldrive").font(.headline); Spacer(); StatusBadge(status: DiagnosticLogic.storageStatus(total: snapshot.diskTotal, available: snapshot.diskAvailable)) }
                                Text("\(DiagnosticLogic.bytes(snapshot.diskAvailable)) available").font(.title2.bold())
                                if let total = snapshot.diskTotal, let available = snapshot.diskAvailable, total > 0 { ProgressView(value: Double(total - available), total: Double(total)).tint(.blue) }
                                Text("\(DiagnosticLogic.bytes(snapshot.diskTotal)) volume capacity. Warning below 15% free; critical below 5%. This does not measure drive wear.").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Surface {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Label("Battery", systemImage: "battery.75").font(.headline); Spacer(); StatusBadge(status: DiagnosticLogic.batteryStatus(snapshot.battery?.health)) }
                                if let battery = snapshot.battery {
                                    Text("\(percent(battery.charge)) charged").font(.title2.bold())
                                    if let charge = battery.charge { ProgressView(value: charge, total: 100).tint(.green) }
                                    Text("\(battery.cycles.map(String.init) ?? "Unknown") cycles · \(percent(battery.health)) design capacity").font(.caption)
                                    Text(battery.charging ? "Charging" : battery.externalPower ? "Connected to power" : "Using battery").font(.caption).foregroundColor(.secondary)
                                    Text("Capacity estimate: warning below 80%; critical below 60%. Not a battery safety test.").font(.caption).foregroundColor(.secondary)
                                } else { Text("No internal battery exposed by macOS.").foregroundColor(.secondary) }
                            }
                        }
                    }
                    if !snapshot.warnings.isEmpty { Surface { VStack(alignment: .leading, spacing: 8) { Label("Scan notices", systemImage: "exclamationmark.triangle").font(.headline); ForEach(snapshot.warnings, id: \.self) { Text($0).font(.callout) } } } }
                } else { ProgressView("Reading this Mac…").frame(maxWidth: .infinity).padding(80) }
                Text("Two-second samples · last two minutes. Memory activity is an estimate, not memory pressure. Interface totals may include virtual adapters. Missing counters are never shown as zero.").font(.caption).foregroundColor(.secondary)
            }.padding(28)
        }
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "Unavailable" }
    private func rate(_ value: Double?) -> String { value.map { DiagnosticLogic.bytes(Int64($0)) + "/s" } ?? "Unavailable" }
}
@MainActor struct MetricCard: View {
    let title: String
    let icon: String
    let value: String
    let subtitle: String
    let samples: [MonitoringSample]
    let key: KeyPath<MonitoringSample, Double?>
    let color: Color
    var isPercent = true
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon).foregroundColor(color).font(.headline)
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(2).frame(height: 30, alignment: .top)
                if #available(macOS 13.0, *) {
                    Chart(samples) { sample in
                        if let value = sample[keyPath: key] { LineMark(x: .value("Time", sample.date), y: .value(title, value)).foregroundStyle(color).interpolationMethod(.linear) }
                    }.chartYScale(domain: 0...(isPercent ? 100 : max(1, samples.compactMap { $0[keyPath: key] }.max() ?? 1))).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 65)
                } else {
                    GeometryReader { geometry in
                        Path { path in
                            let maximum = isPercent ? 100 : max(1, samples.compactMap { $0[keyPath: key] }.max() ?? 1)
                            var connected = false
                            for (index, sample) in samples.enumerated() {
                                guard let value = sample[keyPath: key] else { connected = false; continue }
                                let point = CGPoint(x: CGFloat(index) / CGFloat(max(samples.count - 1, 1)) * geometry.size.width, y: geometry.size.height * (1 - value / maximum))
                                if connected { path.addLine(to: point) } else { path.move(to: point); connected = true }
                            }
                        }.stroke(color, lineWidth: 2)
                    }.frame(height: 65)
                }
            }
        }.animation(.easeInOut(duration: 0.25), value: value).accessibilityElement(children: .combine)
    }
}
