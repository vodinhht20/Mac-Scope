import Foundation
import IOKit
import IOKit.ps
import Darwin

struct LogScan { var events: [LogEvent]; var notes: [String] }

enum SystemScanner {
    static func scan() -> SystemSnapshot {
        var result = SystemSnapshot()
        result.model = sysctlString("hw.model") ?? "Unavailable"
        result.chip = sysctlString("machdep.cpu.brand_string") ?? "Unavailable"
        result.memory = ProcessInfo.processInfo.physicalMemory
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            result.diskTotal = values.volumeTotalCapacity.map(Int64.init)
            result.diskAvailable = values.volumeAvailableCapacity.map(Int64.init)
        } catch { result.warnings.append("Storage information: \(error.localizedDescription)") }
        result.battery = battery()
        result.fields = [
            HardwareField(category: "Mac", title: "Model identifier", value: result.model),
            HardwareField(category: "Processor", title: "Chip", value: result.chip),
            HardwareField(category: "Processor", title: "Logical processors", value: "\(ProcessInfo.processInfo.processorCount)"),
            HardwareField(category: "Memory", title: "Installed memory", value: DiagnosticLogic.bytes(Int64(result.memory))),
            HardwareField(category: "Storage", title: "Startup volume capacity", value: DiagnosticLogic.bytes(result.diskTotal)),
            HardwareField(category: "Storage", title: "Space available", value: DiagnosticLogic.bytes(result.diskAvailable)),
            HardwareField(category: "macOS", title: "Version", value: result.os)
        ]
        // Only selected, non-identifying fields are retained. Serial numbers and UUIDs are never collected.
        do {
            let data = try runProfiler()
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let mappings: [(String, String, [(String, String)])] = [
                ("SPHardwareDataType", "Mac", [("machine_name", "Model"), ("chip_type", "Chip"), ("cpu_type", "Processor")]),
                ("SPDisplaysDataType", "Graphics & displays", [("sppci_model", "GPU"), ("spdisplays_vram", "Video memory"), ("_name", "Display / device"), ("_spdisplays_resolution", "Resolution"), ("spdisplays_resolution", "Resolution")]),
                ("SPStorageDataType", "Storage", [("_name", "Volume"), ("physical_drive", "Drive")]),
                ("SPNetworkDataType", "Network", [("_name", "Interface"), ("type", "Type"), ("interface", "Device")])
            ]
            for (key, category, fields) in mappings {
                var index = 0
                func collect(_ item: Any) {
                    if let dictionary = item as? [String: Any] {
                        for (key, label) in fields {
                            if let value = dictionary[key] as? String, !value.isEmpty {
                                index += 1
                                result.fields.append(HardwareField(category: category, title: "\(label) · \(index)", value: value))
                                if key == "chip_type" { result.chip = value }
                            }
                        }
                        for key in dictionary.keys.sorted() { if let nested = dictionary[key], nested is [Any] || nested is [String: Any] { collect(nested) } }
                    } else if let array = item as? [Any] { array.forEach(collect) }
                }
                if let item = root[key] { collect(item) }
            }
        } catch { result.warnings.append("Detailed inventory unavailable: \(error.localizedDescription)") }
        if let battery = result.battery {
            result.fields += [HardwareField(category: "Battery", title: "Charge", value: battery.charge.map { String(format: "%.0f%%", $0) } ?? "Unavailable"), HardwareField(category: "Battery", title: "Cycle count", value: battery.cycles.map(String.init) ?? "Unavailable"), HardwareField(category: "Battery", title: "Capacity vs. design", value: battery.health.map { String(format: "%.0f%%", $0) } ?? "Unavailable")]
        }
        return result
    }
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
    static func battery() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var result: BatteryInfo?
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            result = BatteryInfo(charge: DiagnosticLogic.ratio((values[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue, (values[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue), charging: values[kIOPSIsChargingKey] as? Bool ?? false, externalPower: values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        guard var battery = result else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Double? { (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.doubleValue }
            if let cycles = number("CycleCount"), cycles >= 0 { battery.cycles = Int(cycles) }
            // Apple Silicon often exposes MaxCapacity as a percentage. Use raw mAh values only.
            if let maximum = number("AppleRawMaxCapacity"), let design = number("DesignCapacity"), maximum > 100, design > 100 {
                battery.health = min(100, maximum / design * 100)
            } else if let maximum = number("MaxCapacity"), let design = number("DesignCapacity"), maximum > 100, design > 100 {
                battery.health = min(100, maximum / design * 100)
            }
        }
        return battery
    }
    static func runProfiler() throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "SPDisplaysDataType", "SPStorageDataType", "SPNetworkDataType", "-json", "-detailLevel", "mini", "-timeout", "15"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { throw NSError(domain: "MacScope", code: 1, userInfo: [NSLocalizedDescriptionKey: "The macOS inventory command failed or timed out. Try again."]) }
        return data
    }
    static func logs() -> LogScan {
        let directories = [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports"), URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        var candidates: [(URL, Date)] = [], notes: [String] = []
        for directory in directories {
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                for url in urls where ["ips", "crash", "panic", "diag"].contains(url.pathExtension.lowercased()) {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    candidates.append((url, date))
                }
            } catch { notes.append("Cannot read \(directory.lastPathComponent): \(error.localizedDescription)") }
        }
        var events: [LogEvent] = []
        for (url, date) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(100) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 65536) ?? Data()
                let raw = String(decoding: data, as: UTF8.self)
                let panic = url.pathExtension == "panic" || raw.contains("panicString")
                events.append(LogEvent(filename: url.lastPathComponent, date: date, severity: panic ? .critical : .warning, summary: panic ? "Kernel panic report — the system stopped unexpectedly." : "Diagnostic report — review the details before attributing a hardware fault.", detail: DiagnosticLogic.redacted(raw)))
            } catch { notes.append("A report could not be read: \(error.localizedDescription)") }
        }
        notes.append("Latest 100 accessible reports; detail limited to 64 KB each. Timestamps are file modification times. Unified system log and protected reports are not included.")
        return LogScan(events: events, notes: notes)
    }
}
