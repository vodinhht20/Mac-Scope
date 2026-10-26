import Foundation
import AVFoundation
import LocalAuthentication
import Network
import Combine

@MainActor final class HardwareTests: ObservableObject {
    @Published var active: TestKind?
    @Published var level: Float = 0
    @Published var mediaReady = false
    @Published var observed: [String] = []
    let cameraSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.macscope.capture")
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var completionTask: Task<Void, Never>?
    private var authentication: LAContext?
    private var store: AppStore?
    private var generation = UUID()
    func run(_ kind: TestKind, store: AppStore) {
        guard store.result(kind).state != .running else { return }
        if let previous = active { finish(previous, .warning, "Test interrupted before confirmation. Retry to complete it.") }
        self.store = store
        generation = UUID()
        let token = generation
        store.set(kind, .running, "Running…")
        switch kind {
        case .hardware:
            Task { await store.scan(); let warnings = store.snapshot?.warnings ?? ["Inventory unavailable."]; store.set(kind, warnings.isEmpty ? .success : .warning, warnings.isEmpty ? "Hardware inventory read successfully. No component stress tests were performed." : warnings.joined(separator: "\n")) }
        case .battery:
            Task {
                let info = await Task.detached { SystemScanner.battery() }.value
                guard let info = info else { store.set(kind, .unsupported, "No internal battery was exposed by macOS."); return }
                let status = DiagnosticLogic.batteryStatus(info.health)
                let capacity = info.health.map { String(format: "%.0f%%", $0) } ?? "unavailable"
                store.set(kind, status == .good ? .success : status == .unsupported ? .unsupported : .warning, "Capacity vs. design: \(capacity). Cycles: \(info.cycles.map(String.init) ?? "unavailable"). Warning below 80%; critical below 60%. This is a capacity estimate, not a safety or runtime test.")
            }
        case .storage:
            Task {
                await store.scan()
                let status = DiagnosticLogic.storageStatus(total: store.snapshot?.diskTotal, available: store.snapshot?.diskAvailable)
                store.set(kind, status == .good ? .success : status == .unsupported ? .unsupported : .warning, "Available: \(DiagnosticLogic.bytes(store.snapshot?.diskAvailable)). Warning below 15% free; critical below 5%. Drive wear, SMART self-tests and filesystem integrity are unsupported.")
            }
        case .network:
            Task { let description = await Self.networkPath(); store.set(kind, description.0 ? .success : .warning, description.1) }
        case .logs:
            Task { await store.loadLogs(); store.set(kind, .warning, "Found \(store.events.count) accessible reports. \(store.logNotes.joined(separator: " ")) No hardware verdict can be inferred from this count.") }
        case .touchID:
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), context.biometryType == .touchID else {
                store.set(kind, .unsupported, error?.localizedDescription ?? "Touch ID is not available or no fingerprints are enrolled."); return
            }
            active = kind; authentication = context
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Verify Touch ID for the MacScope diagnostic you requested.") { [weak self] success, error in
                Task { @MainActor in guard let self = self, self.generation == token else { return }; self.finish(kind, success ? .success : .warning, success ? "macOS successfully verified an enrolled fingerprint." : (error?.localizedDescription ?? "Verification was not completed.")) }
            }
        default:
            active = kind; observed = []; mediaReady = false
            if kind == .speaker { startSpeaker() }
            if kind == .microphone || kind == .camera {
                Task {
                    let type: AVMediaType = kind == .camera ? .video : .audio
                    guard AVCaptureDevice.default(for: type) != nil else {
                        finish(kind, .unsupported, "No compatible \(kind == .camera ? "camera" : "microphone") was found.")
                        return
                    }
                    let granted = await AVCaptureDevice.requestAccess(for: type)
                    guard generation == token, active == kind else { return }
                    guard granted else { finish(kind, .failed, "Permission was denied. Enable MacScope in System Settings → Privacy & Security → \(kind == .camera ? "Camera" : "Microphone"), then retry."); return }
                    if kind == .camera { startCamera(token: token) } else { startMicrophone(token: token) }
                }
            }
        }
    }
    func record(_ event: String) {
        guard active == .keyboard || active == .trackpad else { return }
        if !observed.contains(event) { observed.append(event) }
        if observed.count > 80 { observed.removeFirst() }
    }
    func confirm(_ passed: Bool) {
        guard let active = active else { return }
        let details = observed.isEmpty ? "" : " Observed: " + observed.joined(separator: ", ")
        finish(active, passed ? .success : .failed, (passed ? "User confirmed the interactive check passed." : "User observed an issue during the interactive check. This is not proof of a hardware fault.") + details)
    }
    func cancel() {
        if let active = active { finish(active, .warning, "Test stopped before confirmation. Retry when ready.") }
    }
    private func finish(_ kind: TestKind, _ state: TestState, _ detail: String) {
        store?.set(kind, state, detail)
        stopMedia(); active = nil
    }
    private func stopMedia() {
        generation = UUID()
        completionTask?.cancel(); completionTask = nil
        authentication?.invalidate(); authentication = nil
        audioEngine?.stop(); audioEngine = nil; player = nil
        let session = cameraSession
        captureQueue.async { if session.isRunning { session.stopRunning() }; session.inputs.forEach { session.removeInput($0) } }
        level = 0; mediaReady = false
    }
    private func startSpeaker() {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4), let channels = buffer.floatChannelData else { finish(.speaker, .failed, "Unable to allocate the audio test buffer."); return }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / 44100
            let envelope = min(1, min(time.truncatingRemainder(dividingBy: 2) * 20, (2 - time.truncatingRemainder(dividingBy: 2)) * 20))
            let tone = Float(sin(2 * .pi * 440 * time) * 0.12 * envelope)
            channels[0][index] = time < 2 ? tone : 0
            channels[1][index] = time >= 2 ? tone : 0
        }
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start(); player.scheduleBuffer(buffer); player.play(); audioEngine = engine; self.player = player; mediaReady = true }
        catch { finish(.speaker, .failed, "Audio output could not start: \(error.localizedDescription)") }
    }
    private func startMicrophone(token: UUID) {
        let engine = AVAudioEngine()
        let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { finish(.microphone, .unsupported, "No usable microphone input is available."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var energy: Float = 0
            for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
            let level = min(1, sqrt(energy / Float(buffer.frameLength)) * 8)
            Task { @MainActor [weak self] in guard let self = self, self.generation == token else { return }; self.level = level }
        }
        do { try engine.start(); audioEngine = engine; mediaReady = true }
        catch { input.removeTap(onBus: 0); finish(.microphone, .failed, "Microphone capture failed: \(error.localizedDescription)"); return }
        completionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self = self, self.generation == token else { return }
            self.audioEngine?.stop()
            self.observed.append("Ten-second input observation completed")
        }
    }
    private func startCamera(token: UUID) {
        let session = cameraSession
        captureQueue.async { [weak self] in
            do {
                guard let device = AVCaptureDevice.default(for: .video) else { throw NSError(domain: "MacScope", code: 2, userInfo: [NSLocalizedDescriptionKey: "No camera was found."]) }
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                guard session.canAddInput(input) else { session.commitConfiguration(); throw NSError(domain: "MacScope", code: 3, userInfo: [NSLocalizedDescriptionKey: "The camera cannot be opened. Another application may be using it."]) }
                session.addInput(input); session.commitConfiguration(); session.startRunning()
                Task { @MainActor in guard let self = self, self.generation == token else { return }; self.mediaReady = session.isRunning; if !session.isRunning { self.finish(.camera, .failed, "The camera session did not start. Check permissions and other camera apps.") } }
            } catch { Task { @MainActor in guard let self = self, self.generation == token else { return }; self.finish(.camera, .failed, error.localizedDescription) } }
        }
    }
    private nonisolated static func networkPath() async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(), queue = DispatchQueue(label: "com.macscope.network-test")
            // All completion paths use one serial queue, so continuation is resumed once.
            var finished = false
            monitor.pathUpdateHandler = { path in
                guard !finished else { return }; finished = true
                let interfaces = path.availableInterfaces.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")
                let connected = path.status == .satisfied
                continuation.resume(returning: (connected, "\(connected ? "An active route is available." : "No active route is available. Check Wi-Fi or Ethernet in System Settings.") Interfaces: \(interfaces). Internet access, throughput and signal quality were not tested. No external request was sent."))
                monitor.cancel()
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { guard !finished else { return }; finished = true; monitor.cancel(); continuation.resume(returning: (false, "macOS did not return a network path within eight seconds. Retry the test.")) }
        }
    }
}
