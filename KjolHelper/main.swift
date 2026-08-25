
import Foundation
import XPC
import IOKit
import IOKit.pwr_mgt
import Security


final class KjolHelper: NSObject, KjolHelperProtocol, NSXPCListenerDelegate {

    private let stateDir = "/var/db/kjol"
    private var stateCache: [String: String] = [:]
    private let stateQueue = DispatchQueue(label: "com.lappier.kjol.helper.state")

    override init() {
        super.init()
        setupStateDir()
        let alwaysOn = readState("always_on")
        if alwaysOn == "1" {
            alwaysOnActive = true
            startCaffeinate()
            runPmset(["-a", "sleep", "0", "displaysleep", "10", "hibernatemode", "0", "ttyskeepawake", "1"])
        }

        let batEnabled = readState("battery_limit_enabled") == "1"
        let batLimit = Int(readState("battery_limit")) ?? 80
        if batEnabled {
            try? BatteryController.shared.setChargeLimit(batLimit, enabled: true)
        }

        try? applyFanProfile()
    }

    private func applyFanProfile() throws {
        let fc = FanController.shared
        let savedProfile = readState("fan_profile")
        guard !savedProfile.isEmpty, savedProfile != "auto" else { return }

        let socT = fc.socTemperature() ?? 0
        let cpuT = fc.cpuTemperatures() ?? 0
        let maxT = max(socT, cpuT)

        if savedProfile == "balanced" {
            let minT: Float = 45
            let maxT_Curve: Float = 90
            let ratio = Double(max(0, min(1, (maxT - minT) / (maxT_Curve - minT))))
            let pct = ratio * 100
            for i in 0..<fc.fanCount {
                let info = try fc.fanInfo(i)
                let rpm = info.minRPM + Float(pct / 100.0) * (info.maxRPM - info.minRPM)
                try fc.setManual(i, rpm: rpm)
            }
        } else {
            let pct = Double(readState("fan_rpm_percent")) ?? 0
            for i in 0..<fc.fanCount {
                let info = try fc.fanInfo(i)
                let rpm = info.minRPM + Float(pct / 100.0) * (info.maxRPM - info.minRPM)
                try fc.setManual(i, rpm: rpm)
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
        process.arguments = ["-u", "-i", "-s"]

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

    func setAlwaysOn(_ on: Bool, reply: @escaping (Bool, String) -> Void) {
        if on {
            guard !alwaysOnActive else {
                reply(true, "Always-on already enabled")
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
                reply(true, "Always-on enabled: system stays awake with lid closed")
            } else {
                reply(true, "Always-on enabled, but SleepDisabled could not be "
                          + "cleared — the display may stay on when the lid is "
                          + "closed (\(guardResult.detail))")
            }
        } else {
            alwaysOnActive = false
            stopCaffeinate()
            writeState("always_on", "0")
            runPmset(["-a", "disablesleep", "0"])
            runPmset(["-a", "lowpowermode", "1", "powernap", "1", "sleep", "1", "displaysleep", "10", "disksleep", "10", "standby", "1", "hibernatemode", "3", "lessbright", "1"])
            reply(true, "Always-on disabled")
        }
    }


    func suspendDaemons(_ on: Bool, reply: @escaping (Bool, String) -> Void) {
        suspendNonEssentialDaemons(on)
        writeState("daemons_suspended", on ? "1" : "0")
        reply(true, on ? "Non-essential daemons suspended" : "Daemons restored")
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

    func getStatus(reply: @escaping ([String: Any]) -> Void) {
        reply(hostStatusDict())
    }

    func getFanStatus(reply: @escaping ([String: Any]) -> Void) {
        reply(fanStatusDict())
    }

    func getCombinedStatus(reply: @escaping ([String: Any]) -> Void) {
        reply([
            "host": hostStatusDict(),
            "fans": fanStatusDict()
        ])
    }

    func setFanProfile(_ profile: String, rpmPercent: Double, targetTempC: Double, reply: @escaping (Bool, String) -> Void) {
        let fc = FanController.shared
        let count = fc.fanCount
        guard count > 0 else { reply(false, "No fans detected"); return }

        func percentForProfile() -> Double? {
            switch profile {
            case "auto":     return nil
            case "quiet":    return 25
            case "cool":     return 60
            case "balanced": return nil // handled dynamically
            case "blast":    return 100
            case "custom":   return max(0, min(rpmPercent, 100))
            default:         return nil
            }
        }

        do {
            if profile == "balanced" {
                writeState("fan_profile", "balanced")
                try applyFanProfile()
                reply(true, "Balanced smart fan profile active")
                return
            }

            if profile == "auto" || percentForProfile() == nil {
                fc.setAllAuto()
                writeState("fan_profile", "auto")
                writeState("fan_rpm_percent", "0")
                reply(true, "Fans returned to system control")
                return
            }
            let pct = percentForProfile()!
            writeState("fan_profile", profile)
            writeState("fan_rpm_percent", String(Int(pct)))
            try applyFanProfile()
            reply(true, "Fan profile '\(profile)' set (\(Int(pct))%)")
        } catch {
            reply(false, "Fan control failed: \(error)")
        }
    }

    func setBatteryLimit(_ limit: Int, enabled: Bool, reply: @escaping (Bool, String) -> Void) {
        do {
            try BatteryController.shared.setChargeLimit(limit, enabled: enabled)
            writeState("battery_limit", String(limit))
            writeState("battery_limit_enabled", enabled ? "1" : "0")
            reply(true, enabled ? "Battery charge limit set to \(limit)%" : "Battery charge limit disabled")
        } catch {
            reply(false, "Failed to set battery charge limit: \(error)")
        }
    }

    func getBatteryStatus(reply: @escaping ([String: Any]) -> Void) {
        var info = BatteryController.shared.getBatteryInfo()
        let limit = Int(readState("battery_limit")) ?? 80
        let enabled = readState("battery_limit_enabled") == "1"
        info["limit"] = limit
        info["enabled"] = enabled

        if enabled {
            try? BatteryController.shared.setChargeLimit(limit, enabled: true)
        }

        reply(info)
    }


    private func isValidClient(_ connection: NSXPCConnection) -> Bool {
        var token = connection.auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let clientCode = code else {
            fputs("KjolHelper: Failed to copy guest code from audit token (status \(status))\n", stderr)
            return false
        }

        var requirement: SecRequirement?
        let reqString = "identifier \"com.lappier.kjol\"" as CFString
        let reqStatus = SecRequirementCreateWithString(reqString, [], &requirement)
        guard reqStatus == errSecSuccess, let req = requirement else {
            fputs("KjolHelper: Failed to create SecRequirement (status \(reqStatus))\n", stderr)
            return false
        }

        let validityStatus = SecCodeCheckValidity(clientCode, [], req)
        if validityStatus != errSecSuccess {
            fputs("KjolHelper: Client code signature validation failed (status \(validityStatus))\n", stderr)
            return false
        }
        return true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isValidClient(newConnection) else {
            fputs("KjolHelper: Rejecting unauthorized XPC connection attempt\n", stderr)
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: KjolHelperProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = {
        }

        newConnection.resume()
        return true
    }
}


let listener = NSXPCListener(machServiceName: "com.lappier.kjol.helper")
let helper = KjolHelper()
listener.delegate = helper
listener.resume()

RunLoop.current.run()
