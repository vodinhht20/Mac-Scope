import SwiftUI
import AppKit
import AVFoundation

@MainActor struct TestLabView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var tests = HardwareTests()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Test Lab", subtitle: "Independent checks. Clear evidence. No invented health scores.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(TestKind.allCases) { kind in
                        let result = store.result(kind)
                        Surface {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Image(systemName: kind.icon).font(.title2).foregroundColor(.accentColor); Spacer(); Text(result.state.rawValue).font(.caption.bold()).foregroundColor(stateColor(result.state)) }
                                Text(kind.rawValue).font(.headline)
                                Text(kind.explanation).font(.callout).foregroundColor(.secondary).frame(minHeight: 64, alignment: .top)
                                if result.state != .notTested { Text(result.detail).font(.caption).textSelection(.enabled) }
                                Button { tests.run(kind, store: store) } label: { Label(result.state == .notTested ? "Run Test" : result.state == .running ? "Running…" : "Retry", systemImage: result.state == .running ? "hourglass" : "play.fill") }.disabled(result.state == .running)
                            }
                        }
                    }
                }
            }.padding(28)
        }
        .sheet(item: Binding(get: { tests.active }, set: { if $0 == nil { tests.cancel() } })) { kind in
            InteractiveTestView(kind: kind, tests: tests).frame(width: 650, height: 530)
        }
        .onDisappear { tests.cancel() }
    }
    private func stateColor(_ state: TestState) -> Color { switch state { case .success: return .green; case .warning: return .orange; case .failed: return .red; default: return .secondary } }
}
@MainActor private struct InteractiveTestView: View {
    let kind: TestKind
    @ObservedObject var tests: HardwareTests
    @State private var pattern = 0
    @State private var fullscreen: NSWindow?
    private let colors: [Color] = [.white, .black, .red, .green, .blue]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(kind.rawValue, systemImage: kind.icon).font(.title2.bold()); Spacer(); Button("Stop") { closePattern(); tests.cancel() } }
            Text(kind.explanation).foregroundColor(.secondary)
            Group {
                switch kind {
                case .display:
                    VStack {
                        colors[pattern].overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray)).frame(height: 210)
                        HStack {
                            Button("Next Color") { pattern = (pattern + 1) % colors.count }
                            Button("Full-screen Patterns") { openPattern() }
                        }
                        Text("Inspect each color. Full screen: click to advance; Escape to exit. Move this window to the display you want to inspect.").font(.caption)
                    }
                case .keyboard, .trackpad:
                    InputCapture(isKeyboard: kind == .keyboard) { tests.record($0) }.frame(height: 180).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.5)))
                    ScrollView { Text(tests.observed.isEmpty ? "Click the area above to focus, then try your input." : tests.observed.joined(separator: " · ")).font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 75)
                case .speaker:
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 70)).foregroundColor(.accentColor).frame(maxWidth: .infinity, minHeight: 160)
                    Text("A quiet 440 Hz tone plays left for two seconds, then right for two seconds on the selected system output. Check output and volume in System Settings. Confirm only if you heard both channels.")
                case .microphone:
                    VStack(spacing: 20) { Image(systemName: "mic.fill").font(.system(size: 50)); ProgressView(value: Double(tests.level)).scaleEffect(x: 1, y: 3); Text(tests.observed.isEmpty ? "Speak for ten seconds and watch the meter." : "Capture stopped. Confirm whether the meter responded to your voice.") }.padding(30)
                case .camera:
                    CameraPreview(session: tests.cameraSession).frame(height: 280).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 12))
                case .touchID:
                    ProgressView("Complete the macOS Touch ID prompt…").frame(maxWidth: .infinity, minHeight: 200)
                default: EmptyView()
                }
            }
            Spacer()
            if kind != .touchID {
                HStack { Text("Your confirmation is saved in the report.").font(.caption).foregroundColor(.secondary); Spacer(); Button("I Found an Issue") { closePattern(); tests.confirm(false) }; Button("Looks / Sounds Good") { closePattern(); tests.confirm(true) }.buttonStyle(.borderedProminent).disabled(!canConfirm) }
            }
        }.padding(24).onDisappear { closePattern() }
    }
    private var canConfirm: Bool {
        switch kind {
        case .keyboard, .trackpad: return !tests.observed.isEmpty
        case .speaker, .microphone, .camera: return tests.mediaReady
        default: return true
        }
    }
    private func openPattern() {
        guard fullscreen == nil else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let window = NSWindow(contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        let view = PatternView(frame: window.contentView?.bounds ?? .zero)
        view.closeAction = { closePattern() }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        fullscreen = window
        view.installEscapeMonitor()
    }
    private func closePattern() { (fullscreen?.contentView as? PatternView)?.removeMonitor(); fullscreen?.close(); fullscreen = nil }
}
private final class PatternView: NSView {
    private var index = 0
    private let colors: [NSColor] = [.white, .black, .red, .green, .blue]
    var closeAction: (() -> Void)?
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) { colors[index].setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) { index = (index + 1) % colors.count; needsDisplay = true }
    func installEscapeMonitor() { monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in if event.keyCode == 53 { self?.closeAction?(); return nil }; return event } }
    func removeMonitor() { if let monitor = monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { removeMonitor() }
}
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface(session: session) }
    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}
private final class PreviewSurface: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) { preview = AVCaptureVideoPreviewLayer(session: session); super.init(frame: .zero); wantsLayer = true; preview.videoGravity = .resizeAspect; layer?.addSublayer(preview) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}
private struct InputCapture: NSViewRepresentable {
    let isKeyboard: Bool
    let onEvent: (String) -> Void
    func makeNSView(context: Context) -> InputSurface { let view = InputSurface(); view.isKeyboard = isKeyboard; view.onEvent = onEvent; return view }
    func updateNSView(_ nsView: InputSurface, context: Context) { nsView.onEvent = onEvent }
}
private final class InputSurface: NSView {
    var isKeyboard = false
    var onEvent: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let message = isKeyboard ? "Click here, then press keys\nKey codes only — typed text is not stored" : "Click · Scroll · Pinch · Rotate\nKeep the pointer inside this area"
        (message as NSString).draw(in: bounds.insetBy(dx: 25, dy: 45), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 17)])
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); if !isKeyboard { onEvent?("Primary click") } }
    override func rightMouseDown(with event: NSEvent) { if !isKeyboard { onEvent?("Secondary click") } }
    override func keyDown(with event: NSEvent) { if isKeyboard { onEvent?("Key \(event.keyCode)") } }
    override func flagsChanged(with event: NSEvent) { if isKeyboard { onEvent?("Modifier \(event.keyCode)") } }
    override func scrollWheel(with event: NSEvent) { if !isKeyboard { onEvent?(abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? "Vertical scroll" : "Horizontal scroll") } }
    override func magnify(with event: NSEvent) { if !isKeyboard { onEvent?(event.magnification > 0 ? "Pinch out" : "Pinch in") } }
    override func rotate(with event: NSEvent) { if !isKeyboard { onEvent?("Rotation") } }
}
