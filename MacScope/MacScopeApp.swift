import SwiftUI

@main @MainActor struct MacScopeApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var monitoring = MonitoringService()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).environmentObject(monitoring)
                .frame(minWidth: 850, minHeight: 620)
                .task { if store.snapshot == nil { await store.scan() } }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
@MainActor final class AppStore: ObservableObject {
    @Published var snapshot: SystemSnapshot?
    @Published var scanning = false
    @Published var results = TestKind.allCases.map { DiagnosticResult(kind: $0) }
    @Published var events: [LogEvent] = []
    @Published var logNotes: [String] = []
    @Published var loadingLogs = false
    private var scanTask: Task<SystemSnapshot, Never>?
    func scan() async {
        if let scanTask = scanTask { snapshot = await scanTask.value; return }
        scanning = true
        let task = Task.detached(priority: .utility) { SystemScanner.scan() }
        scanTask = task
        snapshot = await task.value
        scanTask = nil
        scanning = false
    }
    private var logTask: Task<LogScan, Never>?
    func loadLogs() async {
        if let logTask = logTask { let scan = await logTask.value; events = scan.events; logNotes = scan.notes; return }
        loadingLogs = true
        let task = Task.detached(priority: .utility) { SystemScanner.logs() }
        logTask = task
        let scan = await task.value
        events = scan.events; logNotes = scan.notes
        logTask = nil; loadingLogs = false
    }
    func set(_ kind: TestKind, _ state: TestState, _ detail: String) {
        guard let index = results.firstIndex(where: { $0.kind == kind }) else { return }
        results[index] = DiagnosticResult(kind: kind, state: state, detail: detail, date: Date())
    }
    func result(_ kind: TestKind) -> DiagnosticResult { results.first { $0.kind == kind } ?? DiagnosticResult(kind: kind) }
}
private enum Screen: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", hardware = "Hardware Details", tests = "Test Lab", logs = "System Logs", report = "Diagnostic Report"
    var id: String { rawValue }
    var icon: String {
        switch self { case .dashboard: return "square.grid.2x2"; case .hardware: return "desktopcomputer"; case .tests: return "stethoscope"; case .logs: return "list.bullet.rectangle"; case .report: return "doc.richtext" }
    }
}
@MainActor struct ContentView: View {
    @State private var selection: Screen? = .dashboard
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) { Image(systemName: "waveform.path.ecg.rectangle.fill").font(.largeTitle).foregroundColor(.accentColor); Text("MacScope").font(.title2.bold()) }.padding(.horizontal).padding(.top, 22)
                List(Screen.allCases, selection: $selection) { screen in Label(screen.rawValue, systemImage: screen.icon).padding(.vertical, 8).tag(screen) }.listStyle(.sidebar)
                Label("On-device. Always private.", systemImage: "lock.shield").font(.caption).foregroundColor(.secondary).padding()
            }.frame(minWidth: 215)
            Group {
                switch selection ?? .dashboard {
                case .dashboard: DashboardView()
                case .hardware: HardwareView()
                case .tests: TestLabView()
                case .logs: LogsView()
                case .report: ReportView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.navigationTitle("MacScope")
    }
}
@MainActor struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.largeTitle.bold()); Text(subtitle).foregroundColor(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
}
@MainActor struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06))) }
}
extension HealthStatus {
    var color: Color { switch self { case .good: return .green; case .warning: return .orange; case .critical: return .red; case .notTested, .unsupported: return .secondary } }
}
@MainActor struct StatusBadge: View {
    let status: HealthStatus
    var body: some View { Text(status.rawValue).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 5).foregroundColor(status.color).background(status.color.opacity(0.12)).clipShape(Capsule()) }
}
