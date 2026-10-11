// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Read-only AppleSmartBattery properties, VM-pressure sysctl and AppleSMC keys.
// Output: Optional measurements; unsupported or invalid values remain nil.
// Pos: Supplemental sampling for MoleMonitor; call off the main thread.

import Foundation
import IOKit
import Darwin

struct SupplementalSample: Codable {
    var batteryPercent: Double?
    var batteryTemperature: Double?
    var charging: Bool?
    var externalPower: Bool?
    var memoryPressure: String?
    var cpuTemperature: Double?
    var fanRPMs: [Double]?
    var sensorNote: String?
}

enum SupplementalSensors {
    static func read() -> SupplementalSample {
        var sample = SupplementalSample()
        var notes = [String]()
        let battery = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("AppleSmartBattery"))
        var batteryPresent = false
        if battery != 0 {
            defer { IOObjectRelease(battery) }
            batteryPresent = boolProperty(battery, "BatteryInstalled") != false
            if batteryPresent {
                if let current = numberProperty(battery, "CurrentCapacity"),
                   let maximum = numberProperty(battery, "MaxCapacity"),
                   maximum > 0, current >= 0, current <= maximum {
                    sample.batteryPercent = 100 * current / maximum
                }
                sample.charging = boolProperty(battery, "IsCharging")
                sample.externalPower = boolProperty(battery, "ExternalConnected")
            }
        }
        if !batteryPresent { notes.append("未检测到内置电池") }

        // XNU returns userspace dispatch flags, not its internal 0…4 enum.
        // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c
        var pressure: UInt32 = 0
        var pressureSize = MemoryLayout<UInt32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure,
                        &pressureSize, nil, 0) == 0,
           pressureSize == MemoryLayout<UInt32>.size {
            switch pressure {
            case 1: sample.memoryPressure = "normal"
            case 2: sample.memoryPressure = "warning"
            case 4: sample.memoryPressure = "critical"
            default: notes.append("内存压力值未识别")
            }
        } else {
            notes.append("内存压力不可用")
        }

        if let smc = ReadOnlySMC() {
            let temperatures = cpuSensorKeys.compactMap { smc.temperature($0) }
            if !temperatures.isEmpty {
                sample.cpuTemperature = temperatures.reduce(0, +) / Double(temperatures.count)
                notes.append("CPU 为可读传感器均值（\(temperatures.count) 个）")
            } else {
                notes.append("CPU 温度不可用")
            }
            if batteryPresent {
                let batteryTemperatures = ["TB1T", "TB2T"].compactMap { smc.temperature($0) }
                    .filter { $0 <= 90 }
                if !batteryTemperatures.isEmpty {
                    sample.batteryTemperature = batteryTemperatures.reduce(0, +)
                        / Double(batteryTemperatures.count)
                } else {
                    notes.append("电池温度不可用")
                }
            }

            if let count = smc.number("FNum"), count >= 0, count <= 8,
               count.rounded() == count {
                if count == 0 {
                    sample.fanRPMs = []
                    notes.append("设备报告无风扇")
                } else {
                    let rpm = (0..<Int(count)).compactMap { smc.number("F\($0)Ac") }
                    if rpm.count == Int(count), rpm.allSatisfy({ $0 >= 0 && $0 <= 20_000 }) {
                        // A successful zero RPM measurement means a stopped fan.
                        sample.fanRPMs = rpm
                    } else {
                        notes.append("风扇转速采样不完整")
                    }
                }
            } else {
                notes.append("风扇信息不可用")
            }
        } else {
            notes.append("SMC 只读传感器不可用")
        }
        sample.sensorNote = notes.isEmpty ? nil : notes.joined(separator: "；")
        return sample
    }

    private static func numberProperty(_ entry: io_registry_entry_t, _ key: String) -> Double? {
        guard let property = IORegistryEntryCreateCFProperty(entry, key as CFString,
                                                            kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let number = property as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func boolProperty(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        guard let value = numberProperty(entry, key), value == 0 || value == 1 else { return nil }
        return value == 1
    }

    private static let cpuSensorKeys: [String] = {
        var length = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0) == 0,
              length > 0, length < 512 else { return [] }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &length, nil, 0) == 0 else { return [] }
        let brand = String(cString: bytes)
        // Select a known CPU-key family. Never classify arbitrary temperature
        // keys as CPU sensors; unknown hardware is deliberately unavailable.
        if brand.contains("Apple M5") {
            return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R",
                    "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        }
        if brand.contains("Apple M4") {
            return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D",
                    "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        }
        if brand.contains("Apple M3") {
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B",
                    "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        }
        if brand.contains("Apple M2") {
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D",
                    "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        }
        if brand.contains("Apple M1") {
            return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        }
        if brand.contains("Intel") { return ["TCAD", "TC0D", "TC0F"] }
        return []
    }()
}

// The wire layout/command numbers are informed by SMCKit; the CPU key catalog
// is adapted from Stats. Buffer construction, validation and lifecycle here
// are independent; this implementation exposes only key-info and key-read.
// https://github.com/beltex/SMCKit/blob/master/SMCKit/SMC.swift
// https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
// MIT License
// Copyright (c) 2014-2017 beltex <https://github.com/beltex>
// Copyright (c) 2019 Serhiy Mytrovtsiy
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
private final class ReadOnlySMC {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &opened) == KERN_SUCCESS else { return nil }
        connection = opened
    }

    deinit { IOServiceClose(connection) }

    func temperature(_ key: String) -> Double? {
        guard let value = number(key), value > 0, value <= 125 else { return nil }
        return value
    }

    func number(_ key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        var request = [UInt8](repeating: 0, count: 80)
        put32(key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }, offset: 0, into: &request)
        request[42] = 9 // Key information, read-only.
        guard let info = transact(request) else { return nil }
        let size = get32(info, offset: 28)
        guard size > 0, size <= 32 else { return nil }
        let type = get32(info, offset: 32)
        put32(size, offset: 28, into: &request)
        request[42] = 5 // Read bytes, read-only.
        guard let response = transact(request) else { return nil }
        let payload = Array(response[48..<(48 + Int(size))])
        let value: Double
        switch (type, size) {
        case (0x666C7420, 4): // "flt ": native little-endian IEEE-754 on macOS.
            value = Double(Float(bitPattern: get32(payload, offset: 0)))
        case (0x73703738, 2): // "sp78": signed big-endian fixed-point.
            value = Double(Int16(bitPattern: UInt16(payload[0]) << 8 | UInt16(payload[1]))) / 256
        case (0x66706532, 2): // "fpe2": unsigned big-endian fixed-point.
            value = Double(UInt16(payload[0]) << 8 | UInt16(payload[1])) / 4
        case (0x75693820, 1): // "ui8 "
            value = Double(payload[0])
        case (0x75693136, 2): // "ui16"
            value = Double(UInt16(payload[0]) << 8 | UInt16(payload[1]))
        default:
            return nil
        }
        return value.isFinite ? value : nil
    }

    private func transact(_ request: [UInt8]) -> [UInt8]? {
        var response = [UInt8](repeating: 0, count: 80)
        var responseSize = response.count
        let result = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count,
                                          output.baseAddress, &responseSize)
            }
        }
        // Reject transport failures, malformed responses and SMC key errors.
        guard result == KERN_SUCCESS, responseSize == 80, response[40] == 0 else { return nil }
        return response
    }

    private func put32(_ value: UInt32, offset: Int, into bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func get32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
}
