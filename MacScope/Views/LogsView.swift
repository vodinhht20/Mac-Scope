import SwiftUI
@MainActor struct LogsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var filter = "All"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { PageHeader(title: "System logs", subtitle: "Accessible crash and diagnostic reports, with context."); Button("Refresh") { Task { await store.loadLogs() } }.disabled(store.loadingLogs) }
                Picker("Severity", selection: $filter) { Text("All").tag("All"); Text("Warning").tag("Warning"); Text("Critical").tag("Critical") }.pickerStyle(.segmented).frame(maxWidth: 360)
                if store.loadingLogs { ProgressView("Reading reports…") }
                if store.events.isEmpty && !store.loadingLogs { Surface { Text("No accessible reports found. This does not establish that no errors occurred.").foregroundColor(.secondary) } }
                ForEach(store.events.filter { filter == "All" || $0.severity.rawValue == filter }) { event in
                    Surface {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { StatusBadge(status: event.severity); Text(event.date, style: .date); Text(event.date, style: .time); Spacer() }.font(.caption)
                            Text(DiagnosticLogic.redacted(event.filename)).font(.headline)
                            Text(event.summary).foregroundColor(.secondary)
                            DisclosureGroup("Technical details (common identifiers hidden)") { Text(event.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                        }
                    }
                }
                ForEach(store.logNotes, id: \.self) { Text($0).font(.caption).foregroundColor(.secondary) }
                Text("Report contents may include application-specific personal information. Review before sharing. MacScope does not request administrator access.").font(.caption).foregroundColor(.secondary)
            }.padding(28)
        }.task { if store.logNotes.isEmpty { await store.loadLogs() } }
    }
}
