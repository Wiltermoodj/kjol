import Foundation
import Combine
import SwiftUI

final class TelemetryViewModel: ObservableObject {
    @Published var socTemp: Double?
    @Published var cpuTemp: Double?
    @Published var gpuTemp: Double?
    @Published var pCoreCount: Int = 0
    @Published var eCoreCount: Int = 0
    @Published var pCoreUsage: Double = 0
    @Published var eCoreUsage: Double = 0
    @Published var fans: [FanReading] = []
    @Published var batteryCharge: Int = 0
    @Published var isCharging: Bool = false
    @Published var batteryCycles: Int = 0
    @Published var hasCpuSample: Bool = false

    func updateTelemetry(cpu: CpuState, fansDict: [String: Any], batteryDict: [String: Any]) {
        if pCoreCount != cpu.pCoreCount { pCoreCount = cpu.pCoreCount }
        if eCoreCount != cpu.eCoreCount { eCoreCount = cpu.eCoreCount }
        if pCoreUsage != cpu.pCoreUsage { pCoreUsage = cpu.pCoreUsage }
        if eCoreUsage != cpu.eCoreUsage { eCoreUsage = cpu.eCoreUsage }
        if hasCpuSample != cpu.hasSample { hasCpuSample = cpu.hasSample }

        let soc = fansDict["socTemp"] as? Double
        if socTemp != soc { socTemp = soc }
        let cpuT = fansDict["cpuTemp"] as? Double
        if cpuTemp != cpuT { cpuTemp = cpuT }
        let gpuT = fansDict["gpuTemp"] as? Double
        if gpuTemp != gpuT { gpuTemp = gpuT }

        if let rawFans = fansDict["fans"] as? [[Double]] {
            let parsed = rawFans.compactMap { a -> FanReading? in
                guard a.count >= 6 else { return nil }
                return FanReading(index: Int(a[0]), actualRPM: a[1], targetRPM: a[2],
                                  minRPM: a[3], maxRPM: a[4], mode: Int(a[5]))
            }
            if fans != parsed { fans = parsed }
        }

        let chg = batteryDict["chargePercent"] as? Int ?? 0
        if batteryCharge != chg { batteryCharge = chg }
        let chging = batteryDict["isCharging"] as? Bool ?? false
        if isCharging != chging { isCharging = chging }
        let cyc = batteryDict["cycleCount"] as? Int ?? 0
        if batteryCycles != cyc { batteryCycles = cyc }
    }
}

final class FanControlViewModel: ObservableObject {
    @Published var profile: FanProfile = .auto
    @Published var customPercent: Double = 50

    var onProfileChange: ((FanProfile, Double?) -> Void)?

    func updateFromDaemon(profileString: String?, rpmPercent: Double?) {
        if let pStr = profileString, let prof = FanProfile(rawValue: pStr) {
            if profile != prof { profile = prof }
        }
        if let pct = rpmPercent, pct > 0, profile == .custom {
            if customPercent != pct { customPercent = pct }
        }
    }

    func selectProfile(_ newProfile: FanProfile) {
        profile = newProfile
        onProfileChange?(newProfile, profile == .custom ? customPercent : nil)
    }

    func setCustomPercent(_ pct: Double) {
        customPercent = pct
        onProfileChange?(.custom, pct)
    }
}

final class PowerViewModel: ObservableObject {
    @Published var alwaysOn: Bool = false
    @Published var daemonsSuspended: Bool = false
    @Published var chargeLimit: Int = 80
    @Published var limitEnabled: Bool = false

    var onAlwaysOnToggle: ((Bool) -> Void)?
    var onDaemonsToggle: ((Bool) -> Void)?
    var onBatteryLimitChange: ((Int, Bool) -> Void)?

    func updateHostState(hostDict: [String: Any]) {
        let ao = hostDict["always_on"] as? Bool ?? false
        if alwaysOn != ao { alwaysOn = ao }
        let ds = hostDict["daemons_suspended"] as? Bool ?? false
        if daemonsSuspended != ds { daemonsSuspended = ds }
    }

    func updateBatteryState(batteryDict: [String: Any]) {
        let lim = batteryDict["limit"] as? Int ?? 80
        if chargeLimit != lim { chargeLimit = lim }
        let en = batteryDict["enabled"] as? Bool ?? false
        if limitEnabled != en { limitEnabled = en }
    }

    func toggleAlwaysOn(_ on: Bool) {
        alwaysOn = on
        onAlwaysOnToggle?(on)
    }

    func toggleDaemons(_ on: Bool) {
        daemonsSuspended = on
        onDaemonsToggle?(on)
    }

    func setChargeLimit(_ limit: Int, enabled: Bool) {
        chargeLimit = limit
        limitEnabled = enabled
        onBatteryLimitChange?(limit, enabled)
    }
}
