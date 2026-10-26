import Foundation
import Combine
import Darwin
import IOKit
import Network

@MainActor final class MonitoringService: ObservableObject {
    @Published var samples: [MonitoringSample] = []
    @Published var network = "Checking connection…"
    @Published var connected = false
    private let queue = DispatchQueue(label: "com.macscope.monitor", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private let sampler = SystemSampler()
    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let type = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : "Network"
            Task { @MainActor [weak self] in self?.connected = connected; self?.network = connected ? "\(type) connected" : "No active network path" }
        }
        pathMonitor.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
        let sampler = self.sampler
        timer.setEventHandler { [weak self] in
            let sample = sampler.sample()
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.samples.append(sample)
                if self.samples.count > 60 { self.samples.removeFirst(self.samples.count - 60) }
            }
        }
        timer.resume()
        self.timer = timer
    }
    deinit { timer?.cancel(); pathMonitor.cancel() }
}
private final class SystemSampler {
    private var previousCPU: [UInt64]?
    private var previousNetwork: (UInt64, UInt64)?
    private var previousDisk: (UInt64, UInt64)?
    private var previousTime: TimeInterval?
    func sample() -> MonitoringSample {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 } ?? 0
        defer { previousTime = now }
        var cpu: Double?
        var ticks = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let cpuResult = withUnsafeMutablePointer(to: &ticks) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if cpuResult == KERN_SUCCESS {
            let current = [ticks.cpu_ticks.0, ticks.cpu_ticks.1, ticks.cpu_ticks.2, ticks.cpu_ticks.3].map(UInt64.init)
            if let previous = previousCPU, zip(current, previous).allSatisfy({ $0.0 >= $0.1 }) {
                let delta = zip(current, previous).map { $0.0 - $0.1 }
                let total = delta.reduce(0, +)
                if total > 0 { cpu = Double(total - delta[2]) / Double(total) * 100 }
            }
            previousCPU = current
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &vmCount) }
        }
        var memory: Double?
        if vmResult == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(host, &pageSize)
            let used = (Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * Double(pageSize)
            memory = DiagnosticLogic.ratio(used, Double(ProcessInfo.processInfo.physicalMemory))
        }
        let network = networkCounters(), disk = diskCounters()
        func rate(_ current: UInt64?, _ previous: UInt64?) -> Double? {
            guard let current = current, let previous = previous else { return nil }
            return DiagnosticLogic.rate(current: current, previous: previous, elapsed: elapsed)
        }
        let sample = MonitoringSample(cpu: cpu, memory: memory, diskRead: rate(disk?.0, previousDisk?.0), diskWrite: rate(disk?.1, previousDisk?.1), received: rate(network?.0, previousNetwork?.0), sent: rate(network?.1, previousNetwork?.1))
        previousNetwork = network
        previousDisk = disk
        return sample
    }
    private func networkCounters() -> (UInt64, UInt64)? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(first) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let interface = item.pointee
            if interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = interface.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(stats.ifi_ibytes); sent += UInt64(stats.ifi_obytes)
            }
            cursor = interface.ifa_next
        }
        return (received, sent)
    }
    private func diskCounters() -> (UInt64, UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0, found = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: NSNumber], let r = stats["Bytes (Read)"], let w = stats["Bytes (Write)"] {
                read += r.uint64Value; written += w.uint64Value; found = true
            }
            IOObjectRelease(service)
        }
        return found ? (read, written) : nil
    }
}
