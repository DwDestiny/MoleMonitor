// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Mach per-core CPU tick counters (host_processor_info) and the NIC counters from Sampler.
// Output: One (network rate, CPU percent) reading per call; each value is nil when it cannot be computed.
// Pos: Mac-only reader for the live charts (docs/PROJECT.md 4). Created when the panel opens, released when it closes. Not thread-safe: use on one queue.

import Foundation
import Darwin

final class LiveSampler {
    struct Reading {
        var rate: NetworkRate?
        var cpuPercent: Double?
    }

    private let host: mach_port_t
    private var prevTicks: [CPUTicks]?
    private var prevNet: (rx: Int64, tx: Int64, at: Date)?

    init() {
        // One send right for the lifetime of this object; released in deinit.
        host = mach_host_self()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// Reads both counters. The first call only stores a baseline, so it returns nil values.
    func read(at now: Date) -> Reading {
        var reading = Reading()

        if let ticks = readCPUTicks() {
            if let prev = prevTicks { reading.cpuPercent = CPULoad.percent(prev: prev, now: ticks) }
            prevTicks = ticks
        } else {
            prevTicks = nil
        }

        if let counters = Sampler.readNetworkCounters(), let total = NetworkFilter.total(counters) {
            if let prev = prevNet {
                reading.rate = NetworkFilter.rate(prevRx: prev.rx, prevTx: prev.tx, rx: total.rx, tx: total.tx,
                                                  seconds: now.timeIntervalSince(prev.at))
            }
            prevNet = (total.rx, total.tx, now)
        } else {
            prevNet = nil
        }
        return reading
    }

    // UNVERIFIED-ON-MAC: host_processor_info signature and the imported macros PROCESSOR_CPU_LOAD_INFO and CPU_STATE_*
    // (Int32 constants). The cast to processor_flavor_t and Int(...) are written defensively.
    private func readCPUTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(host, processor_flavor_t(PROCESSOR_CPU_LOAD_INFO), &cpuCount, &infoPointer, &infoCount)
        guard status == KERN_SUCCESS, let info = infoPointer, cpuCount > 0 else { return nil }
        defer {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), bytes)
        }
        let states = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(cpuCount) * states else { return nil }
        var out = [CPUTicks]()
        out.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * states
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            out.append(CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                                idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)))
        }
        return out
    }
}
