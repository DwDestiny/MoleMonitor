// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Mach per-core CPU ticks (host_processor_info), the NIC counters from Sampler, sysctl (memory pressure,
//        swap, hardware model, chip, memory size) and ProcessInfo.thermalState.
// Output: One Reading per call; each value is nil when it cannot be computed. MachineInfo for the prompt environment.
// Pos: Mac-only reader behind the 30 s trend tick and the 2 s card tick (docs/DESIGN.md 6.1, 6.2, 8.2). It replaces
//      LiveSampler. Not thread-safe: one instance per queue. The first call of an instance stores a baseline and
//      returns nil for CPU and network rate. Reads only; nothing is written or changed.

import Foundation
import Darwin
import SystemConfiguration

final class SystemSampler {
    struct Reading {
        var cpuPercent: Double?
        var rate: NetworkRate?
        /// The three readings below are filled only when `read(at:slow:)` gets `slow: true`.
        var pressure: MemoryPressure?
        var swapUsed: Int64?
        var thermal: ThermalLevel?
        /// Filled on every call (30 s and 2 s tick): two cheap reads, no new timer (DESIGN_V2.md 5.4).
        /// 100 - kern.memorystatus_level. Nil when the sysctl fails or the level is outside 0...100.
        var pressurePercent: Int?
        /// App, wired and compressed memory from host_statistics64. Nil when the call fails.
        var memory: MemoryBreakdown?
        /// Speed and totals per physical interface (DESIGN_V2.md 6.6, D9). Filled on every call from the same counter read
        /// as `rate`. Nil when the counters cannot be read. Rates inside are nil on the first call.
        var interfaces: [InterfaceRate]?
    }

    struct MachineInfo {
        var model: String?
        var chip: String?
        var memoryBytes: Int64?
        var os: String
    }

    private let host: mach_port_t
    private let memoryTotal: Int64? = SystemSampler.sysctlInt64("hw.memsize")
    private var prevTicks: [CPUTicks]?
    private var prevNet: (rx: Int64, tx: Int64, at: Date)?
    private var prevCounters: (list: [InterfaceCounters], at: Date)?
    /// BSD name to display name, kept in memory only (DESIGN_V2.md D9). Read again only when a physical interface has no
    /// name yet, and at most once per 60 s.
    private var displayNames = [String: String]()
    private var namesReadAt: Date?

    init() {
        // One send right for the lifetime of this object; released in deinit.
        host = mach_host_self()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// CPU and network always. Memory pressure, swap and thermal state only with `slow` (the 30 s tick).
    func read(at now: Date, slow: Bool) -> Reading {
        var reading = Reading()

        if let ticks = readCPUTicks() {
            if let prev = prevTicks { reading.cpuPercent = CPULoad.percent(prev: prev, now: ticks) }
            prevTicks = ticks
        } else {
            prevTicks = nil
        }

        let allCounters = Sampler.readNetworkCounters()
        if let counters = allCounters {
            refreshDisplayNames(for: counters, at: now)
            reading.interfaces = InterfaceRates.make(previous: prevCounters?.list, current: counters,
                                                     seconds: prevCounters.map { now.timeIntervalSince($0.at) } ?? 0,
                                                     displayNames: displayNames)
            prevCounters = (counters, now)
        } else {
            prevCounters = nil
        }
        if let counters = allCounters, let total = NetworkFilter.total(counters) {
            if let prev = prevNet {
                reading.rate = NetworkFilter.rate(prevRx: prev.rx, prevTx: prev.tx, rx: total.rx, tx: total.tx,
                                                  seconds: now.timeIntervalSince(prev.at))
            }
            prevNet = (total.rx, total.tx, now)
        } else {
            prevNet = nil
        }

        reading.pressurePercent = SystemSampler.memoryPressurePercent()
        reading.memory = readMemoryBreakdown()

        if slow {
            reading.pressure = SystemSampler.memoryPressure()
            reading.swapUsed = SystemSampler.swapUsed()
            reading.thermal = SystemSampler.thermalLevel()
        }
        return reading
    }

    // MARK: Interface names

    /// UNVERIFIED-ON-MAC: SCNetworkInterfaceCopyAll lists the hardware services (Wi-Fi, Ethernet, iPhone USB, Thunderbolt
    /// Bridge). An interface it does not list keeps its BSD name. Read only; nothing is configured.
    private func refreshDisplayNames(for counters: [InterfaceCounters], at now: Date) {
        let missing = counters.contains { NetworkFilter.isPhysical($0.name) && displayNames[$0.name] == nil }
        guard missing else { return }
        if let last = namesReadAt, now.timeIntervalSince(last) < 60 { return }
        namesReadAt = now
        var names = [String: String]()
        for item in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(item) as String?,
                  let title = SCNetworkInterfaceGetLocalizedDisplayName(item) as String?, !title.isEmpty else { continue }
            names[bsd] = title
        }
        displayNames = names
    }

    // MARK: CPU

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

    // MARK: Memory, swap, thermal

    /// kern.memorystatus_vm_pressure_level returns the userspace flags 1 (normal), 2 (warning), 4 (critical).
    // UNVERIFIED-ON-MAC: the value set on macOS 15 (same reading as Sensors.swift). Other values give nil, never a guess.
    static func memoryPressure() -> MemoryPressure? {
        var level: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<UInt32>.size else { return nil }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }

    /// `kern.memorystatus_level` is the system's available-memory percent. The pressure percent is 100 minus it.
    /// It is an approximate reading without Apple documentation (DESIGN_V2.md 5.4); the colors never use it.
    // UNVERIFIED-ON-MAC: the sysctl returns a 4 byte integer on macOS 14 and 15.
    static func memoryPressurePercent() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return PressurePercent.from(level: Int(level))
    }

    /// Page counts of host_statistics64(HOST_VM_INFO64), turned into bytes by `MemoryBreakdown.make` (Core).
    // UNVERIFIED-ON-MAC: field names of vm_statistics64 and the HOST_VM_INFO64 flavor constant as imported by Swift.
    private func readMemoryBreakdown() -> MemoryBreakdown? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        return MemoryBreakdown.make(internalPages: Int64(stats.internal_page_count),
                                    purgeablePages: Int64(stats.purgeable_count),
                                    wirePages: Int64(stats.wire_count),
                                    compressorPages: Int64(stats.compressor_page_count),
                                    pageSize: Int64(pageSize), total: memoryTotal)
    }

    /// Bytes of swap in use (vm.swapusage, struct xsw_usage). Nil when the read fails.
    // UNVERIFIED-ON-MAC: xsw_usage is imported with xsu_used as UInt64.
    static func swapUsed() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0, size == MemoryLayout<xsw_usage>.size else { return nil }
        return Int64(clamping: usage.xsu_used)
    }

    static func thermalLevel() -> ThermalLevel? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }

    // MARK: Machine

    static func machineInfo() -> MachineInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var os = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion != 0 { os += ".\(v.patchVersion)" }
        return MachineInfo(model: sysctlString("hw.model"), chip: sysctlString("machdep.cpu.brand_string"),
                           memoryBytes: sysctlInt64("hw.memsize"), os: os)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: buffer)
        return text.isEmpty ? nil : text
    }

    private static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int64>.size, value > 0 else { return nil }
        return value
    }
}
