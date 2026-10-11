// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: The data volume, the kernel interface list (sysctl NET_RT_IFLIST2) and kern.boottime.
// Output: One DiskSample per call (disk capacity, summed physical NIC counters, boot time); reads only.
// Pos: Mac-only reading layer for MonitorEngine (docs/PROJECT.md 3.5, 6.3, 7); parsing and filtering live in Core/NetworkFilter.swift.

import Foundation
import Darwin

enum Sampler {
    static let volumePath = "/System/Volumes/Data"

    struct DiskReading {
        var total: Int64?
        var availImportant: Int64?
        var avail: Int64?
        /// Set when the resource read threw; the fields stay nil.
        var readError: String?
    }

    /// Builds one sample. `previousBoot` stabilises kern.boottime jitter (see BootClock).
    static func sample(src: DiskSource, now: Date, previousBoot: Date?) -> DiskSample {
        let disk = readDisk()
        let counters = readNetworkCounters()
        let boot = bootTime().map { BootClock.stabilized(current: $0, previous: previousBoot) }
        return SampleAssembler.make(t: now, src: src, vol: volumePath, total: disk.total,
                                    availImportant: disk.availImportant, avail: disk.avail, readError: disk.readError,
                                    counters: counters, boot: boot)
    }

    // MARK: Disk

    /// Reads capacity of the data volume. A value that cannot be read stays nil; it is never turned into 0.
    static func readDisk(path: String = volumePath) -> DiskReading {
        let url = URL(fileURLWithPath: path)
        // UNVERIFIED-ON-MAC: key names and URLResourceValues property types (Int? for total/available,
        // Int64? for the important-usage key) are from memory. Fallback: read `try url.resourceValues(forKeys:).allValues`
        // and cast each entry by key.
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        do {
            let v = try url.resourceValues(forKeys: keys)
            return DiskReading(total: v.volumeTotalCapacity.map { Int64($0) },
                               availImportant: v.volumeAvailableCapacityForImportantUsage,
                               avail: v.volumeAvailableCapacity.map { Int64($0) },
                               readError: nil)
        } catch {
            return DiskReading(total: nil, availImportant: nil, avail: nil, readError: "read_failed")
        }
    }

    // MARK: Network counters

    /// 64-bit rx/tx byte counters of every interface, from sysctl(NET_RT_IFLIST2). Nil when the call fails.
    /// Filtering to physical interfaces happens later in NetworkFilter.total.
    static func readNetworkCounters() -> [InterfaceCounters]? {
        // UNVERIFIED-ON-MAC: constants CTL_NET, PF_ROUTE, NET_RT_IFLIST2 imported as Int32 and usable in an [Int32] literal.
        // Fallback: write the numbers directly: [4, 17, 0, 0, 6, 0] (CTL_NET=4, PF_ROUTE=17, NET_RT_IFLIST2=6).
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // The interface list can grow between the size query and the read; retry on ENOMEM and keep slack.
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
            let capacity = length + length / 8 + 1024
            var buffer = [UInt8](repeating: 0, count: capacity)
            var used = capacity
            if sysctl(&mib, u_int(mib.count), &buffer, &used, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            guard used >= 0, used <= capacity else { return nil }
            return parseInterfaceList(buffer, count: used)
        }
        return nil
    }

    /// Reads the if_msghdr2 of each RTM_IFINFO2 message. RouteMessages.walk guarantees offset + length <= count.
    private static func parseInterfaceList(_ buffer: [UInt8], count: Int) -> [InterfaceCounters] {
        // UNVERIFIED-ON-MAC: if_msghdr2 is imported with fields ifm_index and ifm_data.ifi_ibytes/ifi_obytes (UInt64),
        // RTM_IFINFO2 is an Int32 constant, and loadUnaligned accepts the imported (packed) C struct.
        // Fallback for loadUnaligned: copy the message bytes into a local `if_msghdr2()` with
        // withUnsafeMutableBytes { dst in dst.copyBytes(from: ...) }.
        let headerSize = MemoryLayout<if_msghdr2>.size
        var out = [InterfaceCounters]()
        for m in RouteMessages.walk(buffer, count: count) {
            guard Int32(m.type) == RTM_IFINFO2, m.length >= headerSize else { continue }
            let hdr = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: m.offset, as: if_msghdr2.self) }
            var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(UInt32(hdr.ifm_index), &nameBuffer) != nil else { continue }
            let name = nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            out.append(InterfaceCounters(name: name, rxBytes: hdr.ifm_data.ifi_ibytes, txBytes: hdr.ifm_data.ifi_obytes))
        }
        return out
    }

    // MARK: Boot time

    /// kern.boottime rounded down to a second. Nil when the read fails.
    // UNVERIFIED-ON-MAC: sysctlbyname("kern.boottime") fills a struct timeval (16 bytes on arm64). The size check rejects any other size.
    // Fallback: sysctl with mib [CTL_KERN, KERN_BOOTTIME] and the same timeval.
    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}
