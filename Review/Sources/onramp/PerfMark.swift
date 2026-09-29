import Foundation
import Darwin

/// Launch-phase timestamps (ms since the process started) for the perf test. Free when it isn't running.
public enum PerfMark {
    nonisolated(unsafe) public private(set) static var marks: [(String, Double)] = []
    nonisolated public static let enabled = ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "perf"

    nonisolated public static func mark(_ label: String) {
        guard enabled else { return }
        marks.append((label, Date().timeIntervalSince(processStart) * 1000))
    }

    nonisolated public static let processStart: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()
}

import AppKit

public extension NSWindow {
    /// Bring the window forward, except during a self-test: then it opens behind your other
    /// windows, so a test run (perf.sh, a release) never takes over the screen. Captures by
    /// window id still see it.
    @MainActor func present() {
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] != nil { orderBack(nil) } else { makeKeyAndOrderFront(nil) }
    }
}

public extension NSApplication {
    /// Come to the front, except during a self-test (see NSWindow.present).
    @MainActor func activateUnlessTesting() {
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == nil { activate(ignoringOtherApps: true) }
    }
}
