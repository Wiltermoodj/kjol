import Foundation
import XPC
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Security

private let kIOMsgCommon: UInt32 = 0x38 << 26
private let kMsgCanSleep = kIOMsgCommon | 0x270
private let kMsgWillSleep = kIOMsgCommon | 0x280
private let kMsgHasPoweredOn = kIOMsgCommon | 0x300

final class KjolHelper: NSObject, KjolHelperProtocol, NSXPCListenerDelegate {

    private let stateDir = "/var/db/kjol"
    private var stateCache: [String: String] = [:]
    private let stateQueue = DispatchQueue(label: "com.lappier.kjol.helper.state")

    private var iopsRunLoopSource: CFRunLoopSource?
    private var rootPowerPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    private var topUpActive = false
    private var dischargeActive = false
    private var calibrationState = "idle"
    private var calibrationHoldStartTime: Double = 0
    private var calibrationProgress: Double = 0
    private var calibrationMessage = ""

    override init() {
        super.init()
        setupStateDir()
        let alwaysOn = readState("always_on")
        if alwaysOn == "1" {
            alwaysOnActive = true
            startCaffeinate()
            runPmset(["-a", "lowpowermode", "0", "powernap", "0", "sleep", "0", "displaysleep", "10", "disksleep", "0", "standby", "0", "hibernatemode", "0", "ttyskeepawake", "1", "lessbright", "0"])
        }

        topUpActive = readState("top_up_active") == "1"
        dischargeActive = readState("discharge_active") == "1"
        calibrationState = readState("calibration_state").isEmpty ? "idle" : readState("calibration_state")
        evaluateBatteryState()
        evaluateFanManagement()
        setupPowerMonitoring()
    }

    private func setupPowerMonitoring() {
        // 1. Event-driven power source change notification (fired on battery %, charger connect/disconnect)
        let iopsCallback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let helper = Unmanaged<KjolHelper>.fromOpaque(context).takeUnretainedValue()
            helper.onPowerSourceChanged()
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(iopsCallback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            iopsRunLoopSource = source
        }

        // 2. Kernel sleep/wake notifications (re-evaluates limit immediately upon system wake)
        let powerCallback: IOServiceInterestCallback = { refCon, service, messageType, messageArgument in
            guard let refCon = refCon else { return }
            let helper = Unmanaged<KjolHelper>.fromOpaque(refCon).takeUnretainedValue()
            helper.onSystemPowerMessage(messageType: messageType, argument: messageArgument)
        }

        var notifier: io_object_t = 0
        let rootPort = IORegisterForSystemPower(context, &powerNotifyPort, powerCallback, &notifier)
        if rootPort != 0, let notifyPort = powerNotifyPort {
            rootPowerPort = rootPort
            powerNotifier = notifier
            if let rlSource = IONotificationPortGetRunLoopSource(notifyPort)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, .commonModes)
            }
        }
    }

    private var calibrationTimer: DispatchSourceTimer?

    private func evaluateBatteryState() {
        let batLimit = Int(readState("battery_limit")) ?? 80
        let batEnabled = readState("battery_limit_enabled") == "1"
        let sailingDiff = Int(readState("battery_sailing_diff")) ?? 4
        let heatProtEnabled = readState("heat_protection_enabled") == "1"
        let maxTempC = Double(readState("heat_protection_temp")) ?? 36.0

        let oldTopUp = topUpActive
        let oldDischarge = dischargeActive
        let oldCalState = calibrationState

        BatteryController.shared.evaluateBatteryManagement(
            limit: batLimit,
            enabled: batEnabled,
            sailingDiff: sailingDiff,
            topUpActive: &topUpActive,
            dischargeActive: &dischargeActive,
            heatProtectionEnabled: heatProtEnabled,
            maxTempC: maxTempC,
            calibrationState: &calibrationState,
            calibrationHoldStartTime: &calibrationHoldStartTime,
            calibrationProgress: &calibrationProgress,
            calibrationMessage: &calibrationMessage
        )

        if oldTopUp != topUpActive { writeState("top_up_active", topUpActive ? "1" : "0") }
        if oldDischarge != dischargeActive { writeState("discharge_active", dischargeActive ? "1" : "0") }
        if oldCalState != calibrationState { writeState("calibration_state", calibrationState) }

        // Run timer only during active multi-phase calibration
        if calibrationState != "idle" && calibrationState != "completed" {
            startCalibrationTimerIfNeeded()
        } else {
            stopCalibrationTimer()
        }
    }

    private func startCalibrationTimerIfNeeded() {
        guard calibrationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            self?.evaluateBatteryState()
        }
        timer.resume()
        calibrationTimer = timer
    }

    private func stopCalibrationTimer() {
        calibrationTimer?.cancel()
        calibrationTimer = nil
    }

    private func onPowerSourceChanged() {
        evaluateBatteryState()
        evaluateFanManagement()
    }

    private func onSystemPowerMessage(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case kMsgCanSleep, kMsgWillSleep:
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        case kMsgHasPoweredOn:
            evaluateBatteryState()
            evaluateFanManagement()
        default:
            break
        }
    }

    private var fanWatchdogTimer: DispatchSourceTimer?
    private var lastAdaptiveTemp: Float = 0.0
    private var adaptivePeakHoldPct: Double = 0.0
    private var adaptiveHoldUntilTime: Double = 0.0

    private func evaluateFanManagement() {
        let savedProfile = readState("fan_profile")
        if savedProfile.isEmpty || savedProfile == "auto" {
            stopFanWatchdog()
            return
        }

        try? applyFanProfile()
        startFanWatchdogIfNeeded()
    }

    private func startFanWatchdogIfNeeded() {
        guard fanWatchdogTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.tickFanWatchdog()
        }
        timer.resume()
        fanWatchdogTimer = timer
    }

    private func stopFanWatchdog() {
        fanWatchdogTimer?.cancel()
        fanWatchdogTimer = nil
    }

    private func tickFanWatchdog() {
        let savedProfile = readState("fan_profile")
        guard !savedProfile.isEmpty, savedProfile != "auto" else {
            stopFanWatchdog()
            return
        }
        try? applyFanProfile()
    }

    private func applyFanProfile() throws {
        let fc = FanController.shared
        let count = fc.fanCount
        guard count > 0 else { return }

        let savedProfile = readState("fan_profile")
        guard !savedProfile.isEmpty, savedProfile != "auto" else { return }

        var targetPercent: Double = 0.0

        if savedProfile == "adaptive" || savedProfile == "balanced" {
            let socT = fc.socTemperature() ?? 0
            let cpuT = fc.cpuTemperatures() ?? 0
            let currentTemp = max(socT, cpuT)

            let minT: Float = 42.0
            let maxT: Float = 85.0
            let baseRatio = Double(max(0.0, min(1.0, (currentTemp - minT) / (maxT - minT))))
            let calculatedPct = (baseRatio * 100.0)

            // Predictive Thermal Acceleration:
            // Calculate rate of rise ΔT / Δt across 5s watchdog intervals
            let now = Date().timeIntervalSince1970
            if lastAdaptiveTemp > 0 {
                let deltaT = currentTemp - lastAdaptiveTemp
                // Proactively boost target if rapid rise (>= +2°C / 5s) or nearing 68°C+
                if deltaT >= 2.0 || (currentTemp >= 68.0 && deltaT > 0.5) {
                    let proactiveBoost = Double(max(15.0, deltaT * 8.0))
                    let boostedPct = min(100.0, calculatedPct + proactiveBoost)
                    if boostedPct > adaptivePeakHoldPct {
                        adaptivePeakHoldPct = boostedPct
                        adaptiveHoldUntilTime = now + 12.0 // 12-second asymmetric spin-down hold
                    }
                }
            }
            lastAdaptiveTemp = currentTemp

            // Apply 12s spin-down hysteresis to prevent acoustic fan hunting
            if now < adaptiveHoldUntilTime {
                targetPercent = max(calculatedPct, adaptivePeakHoldPct)
            } else {
                targetPercent = calculatedPct
                adaptivePeakHoldPct = calculatedPct
            }
            // Ensure adaptive floor is at least 15% for steady airflow
            targetPercent = max(15.0, min(100.0, targetPercent))
        } else if savedProfile == "quiet" {
            targetPercent = 25.0
        } else if savedProfile == "blast" {
            targetPercent = 100.0
        } else if savedProfile == "custom" {
            targetPercent = max(0.0, min(100.0, Double(readState("fan_rpm_percent")) ?? 50.0))
        }

        // Apply proportional target to each fan and verify persistence
        for i in 0..<count {
            let info = try fc.fanInfo(i)
            let desiredRPM = info.minRPM + Float(targetPercent / 100.0) * (info.maxRPM - info.minRPM)
            // If manual mode was cleared by macOS thermalmonitord (e.g. on lid close) or RPM drifted, re-assert
            if !fc.isManualActive(i) || !fc.isTargetRPMClose(i, target: desiredRPM, tolerance: 75.0) {
                try fc.setManual(i, rpm: desiredRPM)
            }
        }
    }

    private func setupStateDir() {
        try? FileManager.default.createDirectory(atPath: stateDir,
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
    }

    private func writeState(_ key: String, _ value: String) {
        stateQueue.sync {
            stateCache[key] = value
            let path = "\(stateDir)/\(key)"
            try? value.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func readState(_ key: String) -> String {
        return stateQueue.sync {
            if let cached = stateCache[key] {
                return cached
            }
            let value = (try? String(contentsOfFile: "\(stateDir)/\(key)", encoding: .utf8)) ?? ""
            stateCache[key] = value
            return value
        }
    }

    @discardableResult
    private func shell(_ args: [String]) -> (output: String, exitCode: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, task.terminationStatus)
        } catch {
            return (error.localizedDescription, 1)
        }
    }

    private var alwaysOnActive = false
    private var caffeinateProcess: Process?

    private var powerAssertion: IOPMAssertionID = 0
    private var powerAssertionActive = false

    private func setPowerAssertion(_ reason: String) {
        clearPowerAssertion()
        var assertionID: IOPMAssertionID = 0
        let props: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypeNoIdleSleep,
            kIOPMAssertionNameKey: reason,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn
        ]
        let kr = IOPMAssertionCreateWithProperties(props as CFDictionary, &assertionID)
        if kr == kIOReturnSuccess, assertionID != 0 {
            powerAssertion = assertionID
            powerAssertionActive = true
        } else {
            fputs("KjolHelper: IOPMAssertionCreateWithProperties failed: 0x\(String(kr, radix: 16))\n", stderr)
        }
    }

    private func clearPowerAssertion() {
        powerAssertionActive = false
        if powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
    }

    private func startCaffeinate() {
        stopCaffeinate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-i", "-m"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            caffeinateProcess = process
        } catch {
            fputs("KjolHelper: Failed to start caffeinate process: \(error)\n", stderr)
        }
    }

    private func stopCaffeinate() {
        if let process = caffeinateProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        caffeinateProcess = nil
    }

    private func caffeinateRunning() -> Bool {
        return caffeinateProcess?.isRunning ?? false
    }

    func setAlwaysOn(_ on: Bool, reply: @escaping (Bool, NSError?) -> Void) {
        if on {
            guard !alwaysOnActive else {
                reply(true, nil)
                return
            }

            let guardResult = assertSleepDisabledOff()

            startCaffeinate()

            runPmset(["-a", "lowpowermode", "0", "powernap", "0", "sleep", "0", "displaysleep", "10", "disksleep", "0", "standby", "0", "hibernatemode", "0", "ttyskeepawake", "1", "lessbright", "0"])

            writeState("always_on", "1")
            writeState("sleep_disabled_ok", guardResult.ok ? "1" : "0")
            writeState("sleep_disabled_detail", guardResult.detail)
            alwaysOnActive = true
            if guardResult.ok {
                reply(true, nil)
            } else {
                let msg = "Always-on enabled, but SleepDisabled could not be cleared (\(guardResult.detail))"
                reply(true, KjolXPCError.makeNSError(message: msg))
            }
        } else {
            alwaysOnActive = false
            stopCaffeinate()
            writeState("always_on", "0")
            runPmset(["-a", "disablesleep", "0"])
            runPmset(["-a", "lowpowermode", "1", "powernap", "1", "sleep", "1", "displaysleep", "10", "disksleep", "10", "standby", "1", "hibernatemode", "3", "lessbright", "1"])
            reply(true, nil)
        }
    }

    func suspendDaemons(_ on: Bool, reply: @escaping (Bool, NSError?) -> Void) {
        suspendNonEssentialDaemons(on)
        writeState("daemons_suspended", on ? "1" : "0")
        reply(true, nil)
    }

    private func runPmset(_ args: [String]) {
        let result = shell(["/usr/bin/pmset"] + args)
        if result.exitCode != 0 {
            fputs("KjolHelper: pmset failed: \(result.output)\n", stderr)
        }
    }

    @discardableResult
    private func assertSleepDisabledOff() -> (ok: Bool, detail: String) {
        runPmset(["-a", "disablesleep", "0"])

        let probe = shell(["/usr/bin/pmset", "-g"])
        guard probe.exitCode == 0 else {
            return (false, "pmset -g failed (exit \(probe.exitCode))")
        }

        for rawLine in probe.output.split(separator: "\n") {
            let line = rawLine.lowercased()
            guard line.contains("sleepdisabled") || line.contains("disablesleep") else { continue }
            let parts = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard let value = parts.last else { continue }
            if value == "0" {
                return (true, "verified off")
            }
            return (false, "still set to \(value) after write")
        }
        return (true, "flag absent (treated as off)")
    }

    private func suspendNonEssentialDaemons(_ on: Bool) {
        let daemons = [
            "mediaanalysisd",
            "mds",
            "corespotlightd",
            "spindump_agent",
            "syspolicyd",
            "spotlightknowledged",
            "mdworker",
            "managedcorespotlightd",
            "photoanalysisd",
            "mds_stores",
            "backupd",
            "suggestd",
            "routined",
            "knowledge-agent",
            "triald",
            "analyticsd",
            "parsecd",
            "siriknowledged",
            "touristd",
            "coreduetd"
        ]

        let pattern = daemons.joined(separator: "|")
        if on {
            shell(["/usr/bin/mdutil", "-a", "-i", "off"])
            shell(["/usr/bin/pkill", "-STOP", "-f", pattern])
        } else {
            shell(["/usr/bin/mdutil", "-a", "-i", "on"])
            shell(["/usr/bin/pkill", "-CONT", "-f", pattern])
        }
    }

    private func hostStatusDict() -> [String: Any] {
        let alwaysOn = readState("always_on")
        let daemonsSuspended = readState("daemons_suspended")

        return [
            "always_on": alwaysOn == "1",
            "daemons_suspended": daemonsSuspended == "1",
            "caffeinate_running": caffeinateRunning(),
            "caffeinate_pid": caffeinateRunning() ? String(caffeinateProcess!.processIdentifier) : "",
            "sleep_disabled_ok": readState("sleep_disabled_ok") != "0",
            "sleep_disabled_detail": readState("sleep_disabled_detail")
        ]
    }

    private func fanStatusDict() -> [String: Any] {
        let fc = FanController.shared

        let fans = fc.allFans().map { f -> [Double] in
            [Double(f.index), Double(f.actualRPM), Double(f.targetRPM),
             Double(f.minRPM), Double(f.maxRPM), Double(f.mode)]
        }
        var out: [String: Any] = [
            "fanCount": fc.fanCount,
            "fans": fans,
            "profile": readState("fan_profile").isEmpty ? "auto" : readState("fan_profile"),
            "rpmPercent": Double(readState("fan_rpm_percent")) ?? 0
        ]
        if let t = fc.socTemperature() { out["socTemp"] = Double(t) }
        if let t = fc.cpuTemperatures() { out["cpuTemp"] = Double(t) }
        if let t = fc.gpuTemperatures() { out["gpuTemp"] = Double(t) }
        return out
    }

    func getStatus(reply: @escaping ([String: Any]?, NSError?) -> Void) {
        reply(hostStatusDict(), nil)
    }

    func getFanStatus(reply: @escaping ([String: Any]?, NSError?) -> Void) {
        reply(fanStatusDict(), nil)
    }

    func getCombinedStatus(reply: @escaping ([String: Any]?, NSError?) -> Void) {
        reply([
            "host": hostStatusDict(),
            "fans": fanStatusDict()
        ], nil)
    }

    func setFanProfile(_ profile: String, rpmPercent: Double, targetTempC: Double, reply: @escaping (Bool, NSError?) -> Void) {
        let fc = FanController.shared
        let count = fc.fanCount
        guard count > 0 else {
            reply(false, KjolXPCError.makeNSError(message: "No fans detected"))
            return
        }

        if profile == "auto" {
            writeState("fan_profile", "auto")
            writeState("fan_rpm_percent", "0")
            fc.setAllAuto()
            stopFanWatchdog()
            reply(true, nil)
            return
        }

        if profile == "adaptive" || profile == "balanced" {
            writeState("fan_profile", "adaptive")
            writeState("fan_rpm_percent", "0")
            evaluateFanManagement()
            reply(true, nil)
            return
        }

        if profile == "quiet" {
            writeState("fan_profile", "quiet")
            writeState("fan_rpm_percent", "25")
            evaluateFanManagement()
            reply(true, nil)
            return
        }

        if profile == "blast" {
            writeState("fan_profile", "blast")
            writeState("fan_rpm_percent", "100")
            evaluateFanManagement()
            reply(true, nil)
            return
        }

        if profile == "custom" {
            let clamped = max(0, min(rpmPercent, 100))
            writeState("fan_profile", "custom")
            writeState("fan_rpm_percent", String(Int(clamped)))
            evaluateFanManagement()
            reply(true, nil)
            return
        }

        // Default fallback: auto
        writeState("fan_profile", "auto")
        fc.setAllAuto()
        stopFanWatchdog()
        reply(true, nil)
    }

    func setBatteryLimit(_ limit: Int, enabled: Bool, reply: @escaping (Bool, NSError?) -> Void) {
        writeState("battery_limit", String(limit))
        writeState("battery_limit_enabled", enabled ? "1" : "0")
        evaluateBatteryState()
        reply(true, nil)
    }

    func setBatteryLimitAdvanced(_ limit: Int, enabled: Bool, sailingDiff: Int, reply: @escaping (Bool, NSError?) -> Void) {
        writeState("battery_limit", String(limit))
        writeState("battery_limit_enabled", enabled ? "1" : "0")
        writeState("battery_sailing_diff", String(sailingDiff))
        evaluateBatteryState()
        reply(true, nil)
    }

    func setTopUpMode(_ enabled: Bool, reply: @escaping (Bool, NSError?) -> Void) {
        topUpActive = enabled
        writeState("top_up_active", enabled ? "1" : "0")
        evaluateBatteryState()
        reply(true, nil)
    }

    func setDischargeMode(_ enabled: Bool, reply: @escaping (Bool, NSError?) -> Void) {
        dischargeActive = enabled
        writeState("discharge_active", enabled ? "1" : "0")
        evaluateBatteryState()
        reply(true, nil)
    }

    func setHeatProtection(_ enabled: Bool, maxTempC: Double, reply: @escaping (Bool, NSError?) -> Void) {
        writeState("heat_protection_enabled", enabled ? "1" : "0")
        writeState("heat_protection_temp", String(format: "%.1f", maxTempC))
        evaluateBatteryState()
        reply(true, nil)
    }

    func setCalibrationMode(_ action: String, reply: @escaping (Bool, NSError?) -> Void) {
        if action == "start" {
            calibrationState = "charging100"
            calibrationHoldStartTime = 0
            calibrationProgress = 0.0
            calibrationMessage = "Starting battery calibration..."
        } else {
            calibrationState = "idle"
            calibrationHoldStartTime = 0
            calibrationProgress = 0.0
            calibrationMessage = ""
            try? BatteryController.shared.setForcedDischarge(false)
        }
        writeState("calibration_state", calibrationState)
        evaluateBatteryState()
        reply(true, nil)
    }

    func getBatteryStatus(reply: @escaping ([String: Any]?, NSError?) -> Void) {
        evaluateBatteryState()

        var info = BatteryController.shared.getBatteryInfo()
        let limit = Int(readState("battery_limit")) ?? 80
        let enabled = readState("battery_limit_enabled") == "1"
        let sailingDiff = Int(readState("battery_sailing_diff")) ?? 4
        let heatProtEnabled = readState("heat_protection_enabled") == "1"
        let maxTempC = Double(readState("heat_protection_temp")) ?? 36.0

        info["limit"] = limit
        info["enabled"] = enabled
        info["sailingDiff"] = sailingDiff
        info["topUpActive"] = topUpActive
        info["dischargeActive"] = dischargeActive
        info["heatProtectionEnabled"] = heatProtEnabled
        info["maxTempC"] = maxTempC
        info["calibrationState"] = calibrationState
        info["calibrationProgress"] = calibrationProgress
        info["calibrationMessage"] = calibrationMessage

        reply(info, nil)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: KjolHelperProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = {
        }

        newConnection.resume()
        return true
    }
}

// Ensure normal charging and power connections are restored if helper daemon is terminated
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.main)
termSource.setEventHandler {
    try? BatteryController.shared.setForcedDischarge(false)
    try? BatteryController.shared.setInhibitCharging(false)
    exit(0)
}
termSource.resume()

let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.main)
intSource.setEventHandler {
    try? BatteryController.shared.setForcedDischarge(false)
    try? BatteryController.shared.setInhibitCharging(false)
    exit(0)
}
intSource.resume()

let listener = NSXPCListener(machServiceName: "com.lappier.kjol.helper")
let helper = KjolHelper()
listener.delegate = helper
listener.resume()

RunLoop.current.run()

