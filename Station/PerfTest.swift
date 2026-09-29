import AppKit
import Darwin
import StationKit

/// `STATION_SELFTEST=perf`: times what you feel (launch, the first window, switching tabs) and
/// what you don't (the session scan, token counting, CPU and memory while idle), prints one
/// `[perf] {json}` line and quits. scripts/perf.sh holds the budgets.
@MainActor
enum PerfTest {
    private static var results: [String: Double] = [:]
    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// The longest the main thread went without answering, from launch to the end: what you feel as a hitch.
    nonisolated(unsafe) private static var worstStall = 0.0
    nonisolated(unsafe) private static var watching = true
    /// Every stall over 50ms: when it began (ms since launch) and how long it lasted.
    nonisolated(unsafe) private static var stalls: [(at: Double, ms: Double)] = []

    /// Pings the main thread every 5ms from a background thread; a late answer is a stall.
    private static func watchMainThread() {
        Thread.detachNewThread {
            while true {
                guard watching else { usleep(500_000); continue } // off while idle CPU is measured: it's its own load
                let sent = DispatchTime.now().uptimeNanoseconds
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                worstStall = max(worstStall, ms)
                if ms > 50 { stalls.append((Date().timeIntervalSince(PerfMark.processStart) * 1000 - ms, ms)) }
                usleep(5_000)
            }
        }
    }

    static func run() {
        watchMainThread()
        results["launch_to_start_ms"] = (Date().timeIntervalSince(PerfMark.processStart)) * 1000
        let env = ProcessInfo.processInfo.environment
        Task { @MainActor in
            // The first window: open, laid out and drawn.
            var t = now()
            StationHost.openProject(env["STATION_SELFTEST_REPO"] ?? FileManager.default.currentDirectoryPath)
            while StationHost.frontWindow?.isVisible != true { try? await Task.sleep(for: .milliseconds(5)) }
            StationHost.frontWindow?.displayIfNeeded()
            results["first_window_ms"] = (now() - t) * 1000

            // Sessions: the first scan, then token counting (cold: STATION_CONFIG_DIR starts empty).
            let catalog = SessionCatalog.shared
            while catalog.timings.scans < 1 { try? await Task.sleep(for: .milliseconds(20)) }
            results["session_scan_ms"] = catalog.timings.lastScan * 1000
            results["session_files"] = Double(catalog.timings.files)
            while catalog.timings.counts < 1 { try? await Task.sleep(for: .milliseconds(50)) }
            results["token_count_cold_ms"] = catalog.timings.lastCount * 1000

            var warm: [String: [Double]] = [:]
            // Tabs: the first switch builds the view, later ones reuse it. Measured to drawn.
            for mode in [StationMode.agents, .pullRequests, .review] + Array(repeating: [.agents, .pullRequests, .review], count: 5).flatMap({ $0 }) {
                t = now()
                StationHost.show(mode)
                StationHost.frontWindow?.layoutIfNeeded()
                StationHost.frontWindow?.displayIfNeeded()
                let ms = (now() - t) * 1000
                let key = "tab_\(mode == .agents ? "agents" : mode == .pullRequests ? "prs" : "review")"
                if results[key + "_first_ms"] == nil { results[key + "_first_ms"] = ms } else { warm[key, default: []].append(ms) }
                try? await Task.sleep(for: .milliseconds(100))
            }

            for (key, times) in warm { results[key + "_ms"] = times.sorted()[times.count / 2] } // the median: one GC hiccup isn't a regression

            // A steady-state pass: what the 10s timer costs every time.
            let scans = catalog.timings.scans, counts = catalog.timings.counts
            catalog.refresh()
            while catalog.timings.scans == scans || catalog.timings.counts == counts { try? await Task.sleep(for: .milliseconds(20)) }
            results["session_rescan_ms"] = catalog.timings.lastScan * 1000
            results["token_count_warm_ms"] = catalog.timings.lastCount * 1000

            // Idle: the window open on Review, nobody touching it.
            let idle = Double(env["STATION_PERF_IDLE"] ?? "30") ?? 30
            watching = false
            let cpu0 = cpuSeconds(); t = now()
            try? await Task.sleep(for: .seconds(idle))
            results["idle_cpu_pct"] = (cpuSeconds() - cpu0) / (now() - t) * 100
            results["memory_mb"] = footprintMB()
            results["main_stall_max_ms"] = worstStall
            for (i, st) in stalls.prefix(12).enumerated() { results[String(format: "stall%02d_at_%.0f_ms", i, st.at)] = st.ms }

            // What you feel at launch: the first window on screen, and the review in it.
            if let drawn = PerfMark.marks.first(where: { $0.0 == "window-drawn" }) { results["launch_to_window_ms"] = drawn.1 }
            if let loaded = PerfMark.marks.first(where: { $0.0 == "started" }) { results["launch_to_review_ms"] = loaded.1 }
            for (i, (label, ms)) in PerfMark.marks.enumerated() { results[String(format: "mark%02d_%@_ms", i, label)] = ms }
            let json = (try? JSONSerialization.data(withJSONObject: results.mapValues { ($0 * 10).rounded() / 10 }, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            FileHandle.standardError.write("[perf] \(json)\n".data(using: .utf8)!)
            exit(0)
        }
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// What Activity Monitor calls Memory.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
