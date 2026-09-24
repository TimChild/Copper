import AppKit
import Combine
import Darwin
import WebKit

/// Samples the CPU used by WebKit's already-built helper processes. This is
/// deliberately a small observer: asking for `tab.web` here would make a cold
/// tab hot simply because it appeared in the sidebar.
@MainActor
final class Heat: ObservableObject {
    static let shared = Heat()

    struct Reading {
        let pid: pid_t
        let cpu: Double
        let sustained: Double
        let shared: Bool
    }

    @Published private(set) var readings: [UUID: Reading] = [:]
    @Published private(set) var hot: Set<UUID> = []
    @Published private(set) var gpu: Double?

    private struct ProcessSample {
        let cpu: Double
        let time: Double
    }

    private struct Tick {
        let time: Double
        let cpu: Double
    }

    private weak var browser: Browser?
    private var timer: Timer?
    private var processSamples: [pid_t: ProcessSample] = [:]
    private var histories: [UUID: [Tick]] = [:]
    private var lastPIDs: [UUID: pid_t] = [:]
    private var gpuPID: pid_t?
    private var gpuSample: ProcessSample?
    private let timebase: mach_timebase_info_data_t

    private let period: Double = 2
    private let window: Double = 10

    private init() {
        var timebase = mach_timebase_info_data_t()
        _ = mach_timebase_info(&timebase)
        self.timebase = timebase
    }

    /// Starts the one sampler used by the window. Calling this more than once
    /// is harmless, which keeps the Browser hook safe during app restoration.
    func start(for browser: Browser) {
        self.browser = browser
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    func reading(for tab: Tab) -> Reading? {
        readings[tab.id]
    }

    func isHot(_ tab: Tab) -> Bool {
        hot.contains(tab.id)
    }

    /// Bench's `heat` verb: only already-built tabs are reported, preserving
    /// the same no-side-effects rule as the sampler.
    func bench(_ request: [String: Any] = [:], in browser: Browser) -> [String: Any] {
        let tabs = browser.tabs.filter { $0.built != nil }.map { tab -> [String: Any] in
            let reading = readings[tab.id]
            let pid = reading?.pid ?? tab.built.flatMap { webProcessID($0) }
            return [
                "id": tab.id.uuidString,
                "title": tab.label,
                "pid": pid.map { $0 } ?? NSNull(),
                "cpu": reading?.cpu ?? 0,
                "sustained": reading?.sustained ?? 0,
                "shared": reading?.shared ?? false
            ]
        }
        return ["tabs": tabs, "gpu": gpu.map { $0 } ?? NSNull()]
    }

    private func sample() {
        guard let browser else {
            timer?.invalidate()
            timer = nil
            return
        }

        let built = browser.tabs.compactMap { tab -> (Tab, PageView, pid_t)? in
            guard let web = tab.built,
                  let pid = webProcessID(web), pid > 0 else { return nil }
            return (tab, web, pid)
        }
        let now = nanoseconds(mach_absolute_time())
        let pids = Set(built.map { $0.2 })
        var usage: [pid_t: Double] = [:]
        for pid in pids {
            if let cpu = processCPU(pid) {
                usage[pid] = cpu
            } else {
                processSamples.removeValue(forKey: pid)
            }
        }

        var newReadings: [UUID: Reading] = [:]
        var newHot: Set<UUID> = []
        let counts = Dictionary(grouping: built, by: { $0.2 }).mapValues(\.count)
        var activeTabs = Set<UUID>()

        for (tab, _, pid) in built {
            activeTabs.insert(tab.id)
            guard let cpu = usage[pid] else {
                histories.removeValue(forKey: tab.id)
                lastPIDs.removeValue(forKey: tab.id)
                continue
            }
            if lastPIDs[tab.id] != pid {
                histories.removeValue(forKey: tab.id)
                lastPIDs[tab.id] = pid
            }
            guard let previous = processSamples[pid] else { continue }
            let elapsed = max(now - previous.time, 1)
            let current = max((cpu - previous.cpu) / elapsed * 100, 0)
            var history = histories[tab.id, default: []]
            history.append(Tick(time: now, cpu: current))
            history.removeAll { now - $0.time > window }
            histories[tab.id] = history
            let sustained = history.map { $0.cpu }.reduce(0, +) / Double(max(history.count, 1))
            let reading = Reading(pid: pid, cpu: current, sustained: sustained, shared: (counts[pid] ?? 0) > 1)
            newReadings[tab.id] = reading
            // Five two-second deltas cover approximately the requested ten
            // second window; do not call a tab hot on the first noisy tick.
            if history.count >= 5, sustained >= 30 { newHot.insert(tab.id) }
        }

        for pid in processSamples.keys.filter({ !pids.contains($0) }) {
            processSamples.removeValue(forKey: pid)
        }
        for pid in usage {
            processSamples[pid.key] = ProcessSample(cpu: pid.value, time: now)
        }
        for id in histories.keys.filter({ !activeTabs.contains($0) }) {
            histories.removeValue(forKey: id)
            lastPIDs.removeValue(forKey: id)
        }

        readings = newReadings
        hot = newHot
        sampleGPU(now: now, built: built, usage: &usage)
    }

    private func sampleGPU(now: Double, built: [(Tab, PageView, pid_t)], usage: inout [pid_t: Double]) {
        let privateGPU = built.lazy.compactMap { self.gpuProcessID($0.1) }.first
        let candidate = privateGPU ?? gpuPID ?? scanGPUProcess(parent: getpid())
        guard let pid = candidate, let cpu = usage[pid] ?? processCPU(pid) else {
            gpuPID = nil
            gpuSample = nil
            gpu = nil
            return
        }
        gpuPID = pid
        guard let previous = gpuSample else {
            gpuSample = ProcessSample(cpu: cpu, time: now)
            gpu = nil
            return
        }
        let elapsed = max(now - previous.time, 1)
        gpu = max((cpu - previous.cpu) / elapsed * 100, 0)
        gpuSample = ProcessSample(cpu: cpu, time: now)
    }

    private func webProcessID(_ web: PageView) -> pid_t? {
        privateProcessID(web, selector: "_webProcessIdentifier")
    }

    private func gpuProcessID(_ web: PageView) -> pid_t? {
        privateProcessID(web, selector: "_gpuProcessIdentifier")
            ?? privateProcessID(web.configuration.processPool, selector: "_gpuProcessIdentifier")
    }

    /// Private WebKit selectors are optional implementation details. Checking
    /// `responds(to:)` first makes a future WebKit without them a no-reading
    /// case instead of an exception or a forced web-view build.
    private func privateProcessID(_ object: NSObject, selector name: String) -> pid_t? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let value = object.value(forKey: name) as? NSNumber else { return nil }
        let pid = value.int32Value
        return pid > 0 ? pid : nil
    }

    private func processCPU(_ pid: pid_t) -> Double? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        return nanoseconds(info.ri_user_time &+ info.ri_system_time)
    }

    private func nanoseconds(_ absolute: UInt64) -> Double {
        Double(absolute) * Double(timebase.numer) / Double(timebase.denom)
    }

    /// Last-resort GPU lookup for WebKit releases that do not expose the
    /// private GPU selector. Restricting the match to a child of Copper avoids
    /// attributing another app's WebKit GPU helper to this window.
    private func scanGPUProcess(parent: pid_t) -> pid_t? {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 1)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        for pid in pids.prefix(count) where pid > 0 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path).hasSuffix("com.apple.WebKit.GPU") else { continue }
            var info = proc_bsdinfo()
            let infoBytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard infoBytes > 0, info.pbi_ppid == parent else { continue }
            return pid
        }
        return nil
    }
}
