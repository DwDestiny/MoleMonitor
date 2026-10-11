// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: libproc: proc_listallpids, proc_pid_rusage, proc_name, proc_pidpath; the Info.plist of the app bundles.
// Output: [ProcessSample] and ProcessCoverage per scan (docs/DESIGN.md 6.6, 8.2). Ranking is in Core (AppRanking).
// Pos: Mac-only process reader. Scan period: 300 s (all green, card closed), 180 s (any yellow or red), 4 s (card open);
//      the engine decides when to call. Reads only: no command line, no environment, no arguments, no user name.
//      Per process it keeps only the name, the app bundle id and display name (cached), CPU time and memory. Not thread-safe.

import Foundation
import Darwin

final class ProcessSampler {
    struct Scan {
        var samples: [ProcessSample]
        var coverage: ProcessCoverage
    }

    private struct Identity {
        var name: String
        var appKey: String
        var displayName: String
        var bundleID: String?
        var isSystem: Bool
    }

    private struct ProcessKey: Hashable {
        var pid: Int32
        var start: UInt64
    }

    private struct AppInfo {
        var key: String
        var displayName: String
        var bundleID: String?
    }

    private var identities = [ProcessKey: Identity]()
    private var apps = [String: AppInfo]()
    private var timebaseNumer: UInt64 = 1
    private var timebaseDenom: UInt64 = 1

    init() {
        var base = mach_timebase_info_data_t()
        if mach_timebase_info(&base) == KERN_SUCCESS, base.denom != 0 {
            timebaseNumer = UInt64(base.numer)
            timebaseDenom = UInt64(base.denom)
        }
    }

    func scan() -> Scan {
        let hint = proc_listallpids(nil, 0)
        guard hint > 0 else { return Scan(samples: [], coverage: ProcessCoverage(readable: 0, unreadable: 0)) }
        // Slack for processes that start between the two calls. The return value is a count of pids; if it were a
        // byte count, the clamp below and the pid > 0 test keep the loop safe.
        var pids = [pid_t](repeating: 0, count: Int(hint) + 128)
        let returned = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard returned > 0 else { return Scan(samples: [], coverage: ProcessCoverage(readable: 0, unreadable: 0)) }
        let count = min(Int(returned), pids.count)

        var samples = [ProcessSample]()
        samples.reserveCapacity(count)
        var live = Set<ProcessKey>()
        var readable = 0
        var unreadable = 0
        for index in 0..<count {
            let pid = pids[index]
            if pid <= 0 { continue }
            var info = rusage_info_v4()
            // UNVERIFIED-ON-MAC: the rebound pointer type of proc_pid_rusage (rusage_info_t?). Same idiom as other
            // libproc users. RUSAGE_INFO_V4 is imported as Int32.
            let status: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, raw)
                }
            }
            if status != 0 {
                unreadable += 1
                continue
            }
            readable += 1
            let key = ProcessKey(pid: pid, start: info.ri_proc_start_abstime)
            live.insert(key)
            let identity: Identity
            if let cached = identities[key] {
                identity = cached
            } else {
                identity = makeIdentity(pid: pid)
                identities[key] = identity
            }
            let ticks: UInt64 = info.ri_user_time &+ info.ri_system_time
            let nanoseconds: UInt64 = ticks &* timebaseNumer / timebaseDenom
            samples.append(ProcessSample(pid: pid, startAbs: info.ri_proc_start_abstime, name: identity.name,
                                         appKey: identity.appKey, displayName: identity.displayName,
                                         bundleID: identity.bundleID, cpuTimeNs: nanoseconds,
                                         footprint: info.ri_phys_footprint > 0 ? info.ri_phys_footprint : nil,
                                         rss: info.ri_resident_size > 0 ? info.ri_resident_size : nil,
                                         isSystem: identity.isSystem))
        }
        if identities.count > live.count { identities = identities.filter { live.contains($0.key) } }
        return Scan(samples: samples, coverage: ProcessCoverage(readable: readable, unreadable: unreadable))
    }

    // MARK: Identity

    private func makeIdentity(pid: pid_t) -> Identity {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let shortName: String = nameLength > 0 ? String(cString: nameBuffer) : ""
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path: String = pathLength > 0 ? String(cString: pathBuffer) : ""
        let fileName: String = path.isEmpty ? "" : (path as NSString).lastPathComponent
        let name: String = fileName.isEmpty ? (shortName.isEmpty ? "(unknown)" : shortName) : fileName
        let system = ProcessSampler.isSystemPath(path) || name == "kernel_task"

        if let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.upperBound].dropLast())
            let app = appInfo(bundlePath: bundlePath)
            return Identity(name: name, appKey: app.key, displayName: app.displayName, bundleID: app.bundleID, isSystem: system)
        }
        return Identity(name: name, appKey: "proc:" + name, displayName: name, bundleID: nil, isSystem: system)
    }

    private func appInfo(bundlePath: String) -> AppInfo {
        if let cached = apps[bundlePath] { return cached }
        let folder: String = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var bundleID: String?
        var display = folder
        if let bundle = Bundle(path: bundlePath) {
            bundleID = bundle.bundleIdentifier
            if let text = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !text.isEmpty {
                display = text
            } else if let text = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !text.isEmpty {
                display = text
            }
        }
        let key: String = (bundleID?.isEmpty == false ? bundleID : nil) ?? ("app:" + display)
        let info = AppInfo(key: key, displayName: display, bundleID: bundleID)
        apps[bundlePath] = info
        return info
    }

    private static func isSystemPath(_ path: String) -> Bool {
        if path.isEmpty { return true }
        let prefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]
        for prefix in prefixes where path.hasPrefix(prefix) { return true }
        return false
    }
}
