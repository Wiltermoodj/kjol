import Foundation

public struct VersionComparator {
    public static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let clean1 = v1.hasPrefix("v") ? String(v1.dropFirst()) : v1
        let clean2 = v2.hasPrefix("v") ? String(v2.dropFirst()) : v2

        let v1Components = clean1.split(separator: ".").compactMap { Int($0) }
        let v2Components = clean2.split(separator: ".").compactMap { Int($0) }

        let count = max(v1Components.count, v2Components.count)
        for i in 0..<count {
            let n1 = i < v1Components.count ? v1Components[i] : 0
            let n2 = i < v2Components.count ? v2Components[i] : 0
            if n1 > n2 { return true }
            if n1 < n2 { return false }
        }
        return false
    }
}

public struct CalibrationCalculator {
    public static let holdDurationSeconds: TimeInterval = 3600.0
    public static let dischargeTargetFloor: Int = 15

    public static let phase1Weight: Double = 0.3
    public static let phase2Weight: Double = 0.2
    public static let phase3Weight: Double = 0.3
    public static let phase4Weight: Double = 0.2

    public static func calculatePhase1Progress(currentCap: Int) -> Double {
        return Double(max(0, min(100, currentCap))) / 100.0 * phase1Weight
    }

    public static func calculatePhase2Progress(elapsed: TimeInterval, holdTarget: TimeInterval = holdDurationSeconds) -> Double {
        let fraction = min(1.0, max(0.0, elapsed / holdTarget))
        return phase1Weight + fraction * phase2Weight
    }

    public static func calculatePhase3Progress(currentCap: Int, floor: Int = dischargeTargetFloor) -> Double {
        let dischargeFraction = max(0.0, min(1.0, Double(100 - currentCap) / Double(max(1, 100 - floor))))
        return phase1Weight + phase2Weight + dischargeFraction * phase3Weight
    }

    public static func calculatePhase4Progress(currentCap: Int, target: Int, floor: Int = dischargeTargetFloor) -> Double {
        let rechargeFraction = max(0.0, min(1.0, Double(currentCap - floor) / Double(max(1, target - floor))))
        return phase1Weight + phase2Weight + phase3Weight + rechargeFraction * phase4Weight
    }
}

public struct CpuUsageCalculator {
    public static func computeUsage(totalDelta: UInt64, busyDelta: UInt64) -> Double {
        guard totalDelta > 0 else { return 0.0 }
        let raw = (Double(busyDelta) / Double(totalDelta)) * 100.0
        return max(0.0, min(100.0, (raw * 10).rounded() / 10))
    }
}

public protocol SMCProvider {
    func readFloat(_ key: String) throws -> Float
    func writeFloat(_ key: String, _ value: Float) throws
    func readUInt8(_ key: String) throws -> UInt8
    func writeUInt8(_ key: String, _ value: UInt8) throws
    func hasKey(_ key: String) -> Bool
}

public final class MockSMCProvider: SMCProvider {
    private var floatStore: [String: Float] = [:]
    private var uint8Store: [String: UInt8] = [:]

    public init() {}

    public func setFloat(_ key: String, _ value: Float) { floatStore[key] = value }
    public func setUInt8(_ key: String, _ value: UInt8) { uint8Store[key] = value }

    public func readFloat(_ key: String) throws -> Float {
        guard let v = floatStore[key] else { throw NSError(domain: "MockSMC", code: 404) }
        return v
    }

    public func writeFloat(_ key: String, _ value: Float) throws {
        floatStore[key] = value
    }

    public func readUInt8(_ key: String) throws -> UInt8 {
        guard let v = uint8Store[key] else { throw NSError(domain: "MockSMC", code: 404) }
        return v
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        uint8Store[key] = value
    }

    public func hasKey(_ key: String) -> Bool {
        return floatStore[key] != nil || uint8Store[key] != nil
    }
}
