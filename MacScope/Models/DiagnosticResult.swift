import Foundation

enum HealthStatus: String, Codable { case good = "Good", warning = "Warning", critical = "Critical", notTested = "Not Tested", unsupported = "Unsupported" }
enum TestState: String, Codable { case notTested = "Not Tested", running = "Running", success = "Success", warning = "Warning", failed = "Failed", unsupported = "Unsupported" }
enum TestKind: String, CaseIterable, Identifiable, Codable {
    case hardware = "Hardware Scanner", battery = "Battery Diagnostic", storage = "Storage Diagnostic"
    case display = "Display Test", keyboard = "Keyboard Test", trackpad = "Trackpad Test"
    case network = "Wi-Fi / Network Test", speaker = "Speaker Test", microphone = "Microphone Test"
    case camera = "Camera Test", touchID = "Touch ID", logs = "System Logs"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .hardware: return "desktopcomputer"
        case .battery: return "battery.75"
        case .storage: return "internaldrive"
        case .display: return "display"
        case .keyboard: return "keyboard"
        case .trackpad: return "hand.draw"
        case .network: return "wifi"
        case .speaker: return "speaker.wave.2"
        case .microphone: return "mic"
        case .camera: return "camera"
        case .touchID: return "touchid"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
    var explanation: String {
        switch self {
        case .hardware: return "Read the hardware inventory exposed by macOS. This is not a component stress test."
        case .battery: return "Read charge, cycle count and capacity when the battery exposes them."
        case .storage: return "Check space on your startup volume. Flash wear and SMART self-tests are not available here."
        case .display: return "Inspect solid color patterns for stuck pixels, lines and uneven areas."
        case .keyboard: return "Press keys and inspect the detected key codes. Some system shortcuts are reserved by macOS."
        case .trackpad: return "Try clicking, scrolling, pinching and rotating in the input area. macOS cannot identify which pointing device produced every event."
        case .network: return "Inspect the current network path. A connected path does not prove Internet access or Wi-Fi radio health."
        case .speaker: return "Play a local stereo tone and confirm whether both channels are audible."
        case .microphone: return "Speak and inspect input levels for ten seconds. No audio is stored."
        case .camera: return "Inspect a local camera preview. No pictures or video are saved."
        case .touchID: return "Check biometric availability and explicitly request verification. Fingerprint data never leaves macOS."
        case .logs: return "Read accessible crash and panic reports. Missing reports do not establish that the system is healthy."
        }
    }
}
struct DiagnosticResult: Identifiable, Codable {
    var id: String { kind.rawValue }
    let kind: TestKind
    var state: TestState = .notTested
    var detail = "Not run yet."
    var date: Date?
}
struct HardwareField: Identifiable, Codable {
    var id: String { category + title }
    let category: String
    let title: String
    let value: String
}
struct BatteryInfo: Codable {
    var charge: Double?
    var cycles: Int?
    var health: Double?
    var charging: Bool = false
    var externalPower: Bool = false
}
struct SystemSnapshot: Codable {
    var date = Date()
    var model = "Unavailable"
    var chip = "Unavailable"
    var os = ProcessInfo.processInfo.operatingSystemVersionString
    var memory: UInt64 = 0
    var diskTotal: Int64?
    var diskAvailable: Int64?
    var battery: BatteryInfo?
    var fields: [HardwareField] = []
    var warnings: [String] = []
}
struct LogEvent: Identifiable, Codable {
    var id: String { filename }
    let filename: String
    let date: Date
    let severity: HealthStatus
    let summary: String
    let detail: String
}
struct MonitoringSample: Identifiable {
    let id = UUID()
    let date = Date()
    let cpu: Double?
    let memory: Double?
    let diskRead: Double?
    let diskWrite: Double?
    let received: Double?
    let sent: Double?
}
enum DiagnosticLogic {
    static func percent(_ value: Double?) -> Double? {
        guard let value = value, value.isFinite, value >= 0, value <= 100 else { return nil }
        return value
    }
    static func ratio(_ value: Double?, _ total: Double?) -> Double? {
        guard let value = value, let total = total, total > 0 else { return nil }
        return percent(value / total * 100)
    }
    static func batteryStatus(_ health: Double?) -> HealthStatus {
        guard let health = percent(health) else { return .unsupported }
        return health < 60 ? .critical : health < 80 ? .warning : .good
    }
    static func storageStatus(total: Int64?, available: Int64?) -> HealthStatus {
        guard let total = total, let available = available, total > 0, available >= 0, available <= total else { return .unsupported }
        let fraction = Double(available) / Double(total)
        return fraction < 0.05 ? .critical : fraction < 0.15 ? .warning : .good
    }
    static func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, elapsed.isFinite, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }
    static func bytes(_ value: Int64?) -> String {
        guard let value = value, value >= 0 else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    static func redacted(_ text: String) -> String {
        let patterns = [#"/Users/[^/\s\"]+"#, #"/home/[^/\s\"]+"#, #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, #"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"#, #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#]
        return patterns.reduce(text) { result, pattern in result.replacingOccurrences(of: pattern, with: "[hidden]", options: .regularExpression) }
    }
}
