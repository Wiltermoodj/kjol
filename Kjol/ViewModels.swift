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
    @Published var chargingInhibited: Bool = false
    @Published var forcedDischarge: Bool = false
    @Published var heatProtectionActive: Bool = false
    @Published var topUpActive: Bool = false
    @Published var externalConnected: Bool = false
    @Published var batteryCycles: Int = 0
    @Published var batteryTemp: Double?
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
        let inh = batteryDict["chargingInhibited"] as? Bool ?? false
        if chargingInhibited != inh { chargingInhibited = inh }
        let fDis = batteryDict["forcedDischarge"] as? Bool ?? false
        if forcedDischarge != fDis { forcedDischarge = fDis }
        let hProt = batteryDict["heatProtectionActive"] as? Bool ?? false
        if heatProtectionActive != hProt { heatProtectionActive = hProt }
        let tUp = batteryDict["topUpActive"] as? Bool ?? false
        if topUpActive != tUp { topUpActive = tUp }
        let ext = batteryDict["externalConnected"] as? Bool ?? false
        if externalConnected != ext { externalConnected = ext }
        let cyc = batteryDict["cycleCount"] as? Int ?? 0
        if batteryCycles != cyc { batteryCycles = cyc }
        let bTemp = batteryDict["temperature"] as? Double
        if batteryTemp != bTemp { batteryTemp = bTemp }
    }
}

final class FanControlViewModel: ObservableObject {
    @Published var profile: FanProfile = .auto
    @Published var customPercent: Double = 50

    var onProfileChange: ((FanProfile, Double?) -> Void)?
    private var debounceWorkItem: DispatchWorkItem?

    func updateFromDaemon(profileString: String?, rpmPercent: Double?) {
        if let pStr = profileString {
            let normalized = (pStr == "balanced" || pStr == "cool") ? "adaptive" : pStr
            if let prof = FanProfile(rawValue: normalized) {
                if profile != prof { profile = prof }
            }
        }
        if let pct = rpmPercent, pct > 0, profile == .custom {
            if customPercent != pct { customPercent = pct }
        }
    }

    func selectProfile(_ newProfile: FanProfile) {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        profile = newProfile
        onProfileChange?(newProfile, profile == .custom ? customPercent : nil)
    }

    func setCustomPercent(_ pct: Double, immediate: Bool = false) {
        let snapped = round(pct / 5.0) * 5.0
        customPercent = snapped

        debounceWorkItem?.cancel()
        if immediate {
            debounceWorkItem = nil
            onProfileChange?(.custom, snapped)
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.onProfileChange?(.custom, snapped)
            }
            debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        }
    }
}

final class PowerViewModel: ObservableObject {
    @Published var alwaysOn: Bool = false
    @Published var daemonsSuspended: Bool = false
    @Published var chargeLimit: Int = 80
    @Published var limitEnabled: Bool = false
    @Published var sailingDiff: Int = 4
    @Published var topUpActive: Bool = false
    @Published var dischargeActive: Bool = false
    @Published var heatProtectionEnabled: Bool = false
    @Published var maxTempC: Double = 36.0
    @Published var calibrationState: String = "idle"
    @Published var calibrationProgress: Double = 0.0
    @Published var calibrationMessage: String = ""

    var onAlwaysOnToggle: ((Bool) -> Void)?
    var onDaemonsToggle: ((Bool) -> Void)?
    var onBatteryLimitChange: ((Int, Bool) -> Void)?
    var onBatteryLimitAdvancedChange: ((Int, Bool, Int) -> Void)?
    var onTopUpToggle: ((Bool) -> Void)?
    var onDischargeToggle: ((Bool) -> Void)?
    var onHeatProtectionChange: ((Bool, Double) -> Void)?
    var onCalibrationAction: ((String) -> Void)?

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
        let sDiff = batteryDict["sailingDiff"] as? Int ?? 4
        if sailingDiff != sDiff { sailingDiff = sDiff }
        let tUp = batteryDict["topUpActive"] as? Bool ?? false
        if topUpActive != tUp { topUpActive = tUp }
        let dis = batteryDict["dischargeActive"] as? Bool ?? false
        if dischargeActive != dis { dischargeActive = dis }
        let hpEn = batteryDict["heatProtectionEnabled"] as? Bool ?? false
        if heatProtectionEnabled != hpEn { heatProtectionEnabled = hpEn }
        let mTemp = batteryDict["maxTempC"] as? Double ?? 36.0
        if maxTempC != mTemp { maxTempC = mTemp }
        let calState = batteryDict["calibrationState"] as? String ?? "idle"
        if calibrationState != calState { calibrationState = calState }
        let calProg = batteryDict["calibrationProgress"] as? Double ?? 0.0
        if calibrationProgress != calProg { calibrationProgress = calProg }
        let calMsg = batteryDict["calibrationMessage"] as? String ?? ""
        if calibrationMessage != calMsg { calibrationMessage = calMsg }
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
        onBatteryLimitAdvancedChange?(limit, enabled, sailingDiff)
    }

    func setSailingDiff(_ diff: Int) {
        sailingDiff = diff
        onBatteryLimitAdvancedChange?(chargeLimit, limitEnabled, diff)
    }

    func toggleTopUp(_ on: Bool) {
        topUpActive = on
        onTopUpToggle?(on)
    }

    func toggleDischarge(_ on: Bool) {
        dischargeActive = on
        onDischargeToggle?(on)
    }

    func setHeatProtection(enabled: Bool, maxTemp: Double) {
        heatProtectionEnabled = enabled
        maxTempC = maxTemp
        onHeatProtectionChange?(enabled, maxTemp)
    }

    func triggerCalibration(action: String) {
        if action == "start" {
            calibrationState = "charging100"
        } else {
            calibrationState = "idle"
        }
        onCalibrationAction?(action)
    }
}
