import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreText

@MainActor struct ReportView: View {
    @EnvironmentObject private var store: AppStore
    @State private var exportMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Diagnostic report", subtitle: "Evidence you can keep. No composite health score.")
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(summary).font(.title3.bold())
                        Text("Results describe only the checks performed. Manual checks reflect your confirmation. A passed check does not certify all hardware.").foregroundColor(.secondary)
                        Label("Sensitive identifiers excluded", systemImage: "lock.shield").foregroundColor(.green)
                        Text("Exports contain selected inventory and test results. Raw logs, device serials, UUIDs, network addresses, Wi-Fi names and typed text are excluded.").font(.caption).foregroundColor(.secondary)
                        HStack { Button("Export JSON") { export(pdf: false) }; Button("Export PDF") { export(pdf: true) } }.disabled(store.snapshot == nil)
                        if let exportMessage = exportMessage { Text(exportMessage).font(.caption).textSelection(.enabled) }
                    }
                }
                if let snapshot = store.snapshot { Surface { VStack(alignment: .leading, spacing: 8) { Text(snapshot.model).font(.headline); Text(snapshot.chip); Text(snapshot.os); Text("Scanned \(snapshot.date.formatted())").foregroundColor(.secondary) } } }
                ForEach(store.results) { result in
                    Surface { VStack(alignment: .leading, spacing: 8) { HStack { Label(result.kind.rawValue, systemImage: result.kind.icon).font(.headline); Spacer(); Text(result.state.rawValue).font(.caption.bold()) }; Text(result.detail).foregroundColor(.secondary); if let date = result.date { Text(date.formatted()).font(.caption).foregroundColor(.secondary) } } }
                }
                Surface { VStack(alignment: .leading, spacing: 10) { Text("Recommendations").font(.headline); Text("Review warnings and retry interrupted checks. For repeat crashes, back up your files and contact Apple Support. For suspected physical faults, run Apple's built-in Apple Diagnostics; MacScope cannot replace it. For a weak battery, seek service advice. For low free space, review Storage in System Settings.").foregroundColor(.secondary) } }
            }.padding(28)
        }
    }
    private var summary: String {
        let completed = store.results.filter { $0.state == .success }.count
        let attention = store.results.filter { $0.state == .failed || $0.state == .warning }.count
        return "\(completed) checks passed · \(attention) need review · \(store.results.filter { $0.state == .notTested }.count) not tested"
    }
    private func export(pdf: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : .json]
        panel.nameFieldStringValue = "MacScope-Report.\(pdf ? "pdf" : "json")"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let report = ExportReport(created: Date(), summary: summary, snapshot: store.snapshot, results: store.results)
                if pdf { try ReportExporter.pdf(report: report, to: url) }
                else { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; try encoder.encode(report).write(to: url, options: .atomic) }
                exportMessage = "Saved \(url.lastPathComponent)."
            } catch { exportMessage = "Export failed: \(error.localizedDescription). Choose another destination and try again." }
        }
    }
}
private struct ExportReport: Encodable {
    let created: Date
    let summary: String
    let snapshot: SystemSnapshot?
    let results: [DiagnosticResult]
    let privacy = "Selected inventory and test results only. Serial numbers, UUIDs, addresses, Wi-Fi names, typed text and raw diagnostic logs are excluded."
    let limitations = "No composite health score. User-confirmed checks are subjective. Storage wear, stress testing, protected logs and Apple proprietary diagnostics are unsupported. Capacity thresholds: battery warning <80%, critical <60%; storage warning <15% free, critical <5%."
}
private enum ReportExporter {
    static func pdf(report: ExportReport, to url: URL) throws {
        let text = NSMutableAttributedString(string: "")
        func append(_ value: String, heading: Bool = false) {
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 8
            text.append(NSAttributedString(string: value + "\n", attributes: [.font: heading ? NSFont.boldSystemFont(ofSize: 17) : NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]))
        }
        append("MacScope Diagnostic Report", heading: true)
        append(report.created.formatted()); append(report.summary, heading: true); append(report.privacy); append(report.limitations)
        if let snapshot = report.snapshot {
            append("Device information", heading: true)
            append("Scan time: \(snapshot.date.formatted())")
            for field in snapshot.fields { append("\(field.category) / \(field.title): \(field.value)") }
            for warning in snapshot.warnings { append("Notice: \(warning)") }
        }
        append("Individual results", heading: true)
        for result in report.results { append("\(result.kind.rawValue) — \(result.state.rawValue)", heading: true); if let date = result.date { append(date.formatted()) }; append(result.detail) }
        append("Recommendations", heading: true)
        append("Review warnings and retry incomplete checks. Back up important files before seeking service for repeated crashes. Use Apple Diagnostics for supported component diagnostics. Review Storage in System Settings for low free space.")
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw exportError() }
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw exportError() }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var location = 0, pageNumber = 1
        while location < text.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: CGRect(x: 44, y: 50, width: 507, height: 744), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let footer = NSAttributedString(string: "MacScope · \(pageNumber)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
            context.textPosition = CGPoint(x: 44, y: 25); CTLineDraw(CTLineCreateWithAttributedString(footer as CFAttributedString), context)
            context.endPDFPage()
            let range = CTFrameGetVisibleStringRange(frame)
            guard range.length > 0 else { context.closePDF(); throw exportError() }
            location += range.length; pageNumber += 1
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }
    private static func exportError() -> NSError { NSError(domain: "MacScope", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create the PDF document."]) }
}
