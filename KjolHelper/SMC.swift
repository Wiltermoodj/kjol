// SMC.swift — pure-Swift AppleSMC client for the Kjol helper.
//
// Reads/writes SMC keys via IOKit (service "AppleSMC", connection type 0,
// selector 2). Works on Apple Silicon (4-byte little-endian float "flt "
// values) and Intel (FPE2). Reads work unprivileged; writes require root —
// this file is compiled into the privileged helper.
//
// Key map (Apple Silicon):
//   FNum  ui8   number of fans
//   F%dAc flt   actual RPM (read-only)
//   F%dTg flt   target RPM
//   F%dMn flt   min RPM   F%dMx flt   max RPM
//   F%dMd ui8   mode: 0=auto 1=manual 3=system (M5 uses lowercase F%dmd)
//   Ftst  ui8   thermalmonitord inhibit flag (M2-M4 unlock; absent M1/M5)
//   Tp??  flt   temperature sensors

import Foundation
import IOKit

// MARK: - SMC param struct (80 bytes)

struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: IOByteCount32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readKeyInfo = 9
}

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcError(UInt8)          // result byte, e.g. 0x84 = key not found
    case keyNotFound(String)

    var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let k): return "IOServiceOpen failed: \(k)"
        case .callFailed(let k): return "IOConnectCallStructMethod failed: \(k)"
        case .smcError(let r): return r == 0x84 ? "SMC key not found (0x84)" : "SMC error result: 0x\(String(r, radix: 16))"
        case .keyNotFound(let k): return "SMC key not found: \(k)"
        }
    }
}

// MARK: - SMC client

final class SMC {
    static let shared = SMC()
    private var conn: io_connect_t = 0
    private let lock = NSLock()

    private init() {}
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func ensureOpen() throws {
        if conn != 0 { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { conn = 0; throw SMCError.openFailed(kr) }
    }

    private static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8.prefix(4) { r = (r << 8) | UInt32(c) }
        return r
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        try ensureOpen()
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let inSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, inSize, &output, &outSize)
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        guard output.result == 0 else { throw SMCError.smcError(output.result) }
        return output
    }

    /// Returns (dataSize, dataType fourCC).
    func keyInfo(_ key: String) throws -> (size: UInt32, type: UInt32) {
        lock.lock(); defer { lock.unlock() }
        var p = SMCParamStruct()
        p.key = Self.fourCC(key)
        p.data8 = SMCCommand.readKeyInfo.rawValue
        let out = try call(&p)
        return (UInt32(out.keyInfo.dataSize), out.keyInfo.dataType)
    }

    func hasKey(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func readBytes(_ key: String) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var info = SMCParamStruct()
        info.key = Self.fourCC(key)
        info.data8 = SMCCommand.readKeyInfo.rawValue
        let infoOut = try call(&info)
        let size = Int(infoOut.keyInfo.dataSize)

        var p = SMCParamStruct()
        p.key = Self.fourCC(key)
        p.keyInfo.dataSize = infoOut.keyInfo.dataSize
        p.data8 = SMCCommand.readBytes.rawValue
        let out = try call(&p)
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
    }

    func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        var info = SMCParamStruct()
        info.key = Self.fourCC(key)
        info.data8 = SMCCommand.readKeyInfo.rawValue
        let infoOut = try call(&info)

        var p = SMCParamStruct()
        p.key = Self.fourCC(key)
        p.keyInfo.dataSize = infoOut.keyInfo.dataSize
        p.data8 = SMCCommand.writeBytes.rawValue
        withUnsafeMutableBytes(of: &p.bytes) { buf in
            for (i, b) in bytes.prefix(32).enumerated() { buf[i] = b }
        }
        _ = try call(&p)
    }

    // MARK: Typed accessors

    /// Read float value — handles Apple Silicon "flt " (LE float) and Intel FPE2.
    func readFloat(_ key: String) throws -> Float {
        let info = try keyInfo(key)
        let bytes = try readBytes(key)
        let fltType = Self.fourCC("flt ")
        let fpe2Type = Self.fourCC("fpe2")
        if info.type == fltType, bytes.count >= 4 {
            return bytes.withUnsafeBytes { $0.load(as: Float32.self) }
        } else if info.type == fpe2Type, bytes.count >= 2 {
            return Float(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        } else if bytes.count >= 4 {
            return bytes.withUnsafeBytes { $0.load(as: Float32.self) }
        }
        throw SMCError.keyNotFound(key)
    }

    func writeFloat(_ key: String, _ value: Float) throws {
        var v = value
        let bytes = withUnsafeBytes(of: &v) { Array($0) }
        try writeBytes(key, bytes)
    }

    func readUInt8(_ key: String) throws -> UInt8 {
        let bytes = try readBytes(key)
        guard let b = bytes.first else { throw SMCError.keyNotFound(key) }
        return b
    }

    func writeUInt8(_ key: String, _ value: UInt8) throws {
        try writeBytes(key, [value])
    }
}

// MARK: - Fan controller

struct FanInfo: Codable {
    var index: Int
    var actualRPM: Float
    var targetRPM: Float
    var minRPM: Float
    var maxRPM: Float
    var mode: UInt8         // 0=auto 1=manual 3=system
}

final class FanController {
    static let shared = FanController()
    private let smc = SMC.shared

    /// Uppercase or lowercase mode key, detected per machine (M5 uses lowercase).
    private lazy var modeKeyFormat: String = {
        if smc.hasKey("F0Md") { return "F%dMd" }
        if smc.hasKey("F0md") { return "F%dmd" }
        return "F%dMd"
    }()

    private func modeKey(_ i: Int) -> String { String(format: modeKeyFormat, i) }

    var fanCount: Int {
        (try? Int(smc.readUInt8("FNum"))) ?? 0
    }

    func fanInfo(_ i: Int) throws -> FanInfo {
        FanInfo(index: i,
                actualRPM: (try? smc.readFloat("F\(i)Ac")) ?? 0,
                targetRPM: (try? smc.readFloat("F\(i)Tg")) ?? 0,
                minRPM: (try? smc.readFloat("F\(i)Mn")) ?? 0,
                maxRPM: (try? smc.readFloat("F\(i)Mx")) ?? 0,
                mode: (try? smc.readUInt8(modeKey(i))) ?? 0)
    }

    func allFans() -> [FanInfo] {
        (0..<fanCount).compactMap { try? fanInfo($0) }
    }

    /// Set a fan to manual mode at the given RPM (clamped to [min, max]).
    /// Handles the M2-M4 Ftst unlock if a direct mode write fails.
    func setManual(_ i: Int, rpm: Float) throws {
        let info = try fanInfo(i)
        let clamped = max(info.minRPM, min(rpm, info.maxRPM))
        let mk = modeKey(i)

        // 1. Try direct manual-mode write (works on M1, M5).
        do {
            try smc.writeUInt8(mk, 1)
        } catch {
            // 2. Fall back to Ftst unlock (M2/M3/M4).
            guard smc.hasKey("Ftst") else { throw error }
            try smc.writeUInt8("Ftst", 1)
            var unlocked = false
            for _ in 0..<12 {  // up to ~6 s
                Thread.sleep(forTimeInterval: 0.5)
                if let m = try? smc.readUInt8(mk), m != 3 {
                    if (try? smc.writeUInt8(mk, 1)) != nil { unlocked = true; break }
                }
            }
            guard unlocked else { throw error }
        }
        try smc.writeFloat("F\(i)Tg", clamped)
    }

    /// Return a fan to automatic/system control.
    func setAuto(_ i: Int) throws {
        try? smc.writeUInt8(modeKey(i), 0)
        // If no fan remains manual, release the Ftst inhibit.
        let anyManual = allFans().contains { $0.mode == 1 }
        if !anyManual, smc.hasKey("Ftst"), (try? smc.readUInt8("Ftst")) == 1 {
            try? smc.writeUInt8("Ftst", 0)
        }
    }

    func setAllAuto() {
        for i in 0..<fanCount { try? setAuto(i) }
    }

    // MARK: Temperature sensors

    /// Best-effort SoC temperature (max across known Apple Silicon Tp keys).
    func socTemperature() -> Float? {
        let candidates = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        let temps = candidates.compactMap { k -> Float? in
            guard let t = try? smc.readFloat(k), t > 5, t < 130 else { return nil }
            return t
        }
        return temps.max()
    }
}
