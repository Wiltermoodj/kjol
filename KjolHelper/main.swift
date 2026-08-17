// KjolHelper — privileged helper for the Kjol menu-bar app.
//
// Installed as a LaunchDaemon (com.lappier.kjol.helper) via SMJobBless.
// Receives XPC commands from the Kjol app and executes root-level
// power-management operations (pmset, IOPMAssertion, daemon control).
//
// Build:
//   swiftc -O KjolHelper/main.swift -o build/KjolHelper
//
// The helper communicates via XPC using the protocol defined in
// KjolHelper/KjolHelperProtocol.swift.

import Foundation
import XPC
import IOKit
import IOKit.pwr_mgt

// MARK: - Helper Implementation

final class KjolHelper: NSObject, KjolHelperProtocol, NSXPCListenerDelegate {

    // State file location (shared between app and helper via /var/root or a
    // world-readable location). We use /var/db/kjol/ for daemon-owned state.
    private let stateDir = "/var/db/kjol"
    private var stateCache: [String: String] = [:]
    private let stateQueue = DispatchQueue(label: "com.lappier.kjol.helper.state")

    override init() {
        super.init()
        setupStateDir()
        // Self-heal: if the helper was restarted after a crash/update, we
        // want to keep the "always_on" state persisting per user request.
        let alwaysOn = readState("always_on")
        if alwaysOn == "1" {
            alwaysOnActive = true
            // Re-apply the caffeinate and pmset rules to ensure the machine stays awake
            startCaffeinate()
            runPmset(["-a", "sleep", "0", "displaysleep", "10", "hibernatemode", "0", "ttyskeepawake", "1"])
        }
    }

    private func setupStateDir() {
        try? FileManager.default.createDirectory(atPath: stateDir,
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o755])
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

    // MARK: - Shell

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

    // MARK: - Power Modes

    func setPowerMode(_ mode: String, reply: @escaping (Bool, String) -> Void) {
        var success = true
        var message = ""

        switch mode {
        case "normal":
            // macOS defaults: low power on, sleep on, Spotlight on
            runPmset(["-a", "lowpowermode", "1", "powernap", "1", "sleep", "1", "displaysleep", "10", "disksleep", "10", "standby", "1", "hibernatemode", "3", "lessbright", "1", "disablesleep", "0"])
            clearPowerAssertion()
            message = "Normal: macOS defaults restored"

        case "serving":
            // Keep awake, low power off, Spotlight on
            runPmset(["-a", "lowpowermode", "0", "powernap", "0", "sleep", "0", "displaysleep", "10", "disksleep", "0", "standby", "0", "hibernatemode", "0", "ttyskeepawake", "1", "lessbright", "0", "disablesleep", "0"])
            setPowerAssertion("Kjol serving")
            message = "Serving: awake, low power off"

        case "max":
            // Aggressive: sleep off, Spotlight off, daemons suspended
            runPmset(["-a", "lowpowermode", "0", "powernap", "0", "sleep", "0", "displaysleep", "1", "disksleep", "0", "standby", "0", "hibernatemode", "0", "ttyskeepawake", "1", "lessbright", "0", "disablesleep", "0"])
            setPowerAssertion("Kjol max")
            suspendNonEssentialDaemons(true)
            message = "Max: all optimizations on"

        default:
            success = false
            message = "Unknown mode: \(mode)"
        }

        if success {
            writeState("mode", mode)
        }
        reply(success, message)
    }

    // MARK: - Always-On (lid closed)

    private var alwaysOnActive = false
    private let caffeinateJobLabel = "com.lappier.kjol.caffeinate"
    private let caffeinatePlist = "/Library/LaunchDaemons/com.lappier.kjol.caffeinate.plist"

    private var powerAssertion: IOPMAssertionID = 0
    private var powerAssertionActive = false

    private func setPowerAssertion(_ reason: String) {
        clearPowerAssertion()
        var assertionID: IOPMAssertionID = 0
        let kr = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(1),
            reason as CFString,
            &assertionID
        )
        if kr == kIOReturnSuccess, assertionID != 0 {
            powerAssertion = assertionID
            powerAssertionActive = true
        } else {
            fputs("KjolHelper: IOPMAssertionCreateWithName failed: 0x\(String(kr, radix: 16))\n", stderr)
        }
    }

    private func clearPowerAssertion() {
        powerAssertionActive = false
        if powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
    }

    private func installCaffeinateJob() {
        let src = Bundle.main.bundlePath + "/Contents/Library/LaunchDaemons/com.lappier.kjol.caffeinate.plist"
        let cmds = [
            "mkdir -p /Library/LaunchDaemons /var/log",
            "cp '\(src)' '\(caffeinatePlist)'",
            "chown root:wheel '\(caffeinatePlist)'",
            "chmod 644 '\(caffeinatePlist)'",
            "launchctl bootstrap system '\(caffeinatePlist)' 2>/dev/null || launchctl load '\(caffeinatePlist)' 2>/dev/null || true"
        ].joined(separator: " && ")
        shell(["/bin/sh", "-c", cmds])
    }

    private func startCaffeinate() {
        stopCaffeinate()
        installCaffeinateJob()
        // Start it manually in case bootstrap/load didn't fire.
        shell(["/bin/launchctl", "kickstart", "-k", "system/\(caffeinateJobLabel)"])
    }

    private func stopCaffeinate() {
        shell(["/bin/launchctl", "bootout", "system/\(caffeinateJobLabel)"])
        shell(["/bin/launchctl", "unload", caffeinatePlist])
    }

    private func caffeinateRunning() -> Bool {
        return alwaysOnActive
    }

    func setAlwaysOn(_ on: Bool, reply: @escaping (Bool, String) -> Void) {
        if on {
            guard !alwaysOnActive else {
                reply(true, "Always-on already enabled")
                return
            }

            // Always-on means: keep system awake even with lid closed.
            // We hold that with `caffeinate -u -i -s`, but we let launchd
            // own the process lifetime. The helper installs/removes the
            // job; launchd respawns it if it ever dies.
            //
            // We intentionally do NOT set disablesleep=1, because that would
            // prevent the display from sleeping when the lid is closed.
            //
            // F3 guard: SleepDisabled is separate from sleep/displaysleep.
            // If another app left it enabled, the display cannot sleep on
            // lid-close. Assert it off here too, and verify.
            let guardResult = assertSleepDisabledOff()

            startCaffeinate()

            runPmset(["-a", "sleep", "0", "displaysleep", "10", "hibernatemode", "0", "ttyskeepawake", "1"])

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
            let mode = readState("mode")
            reapplyMode(mode.isEmpty ? "normal" : mode)
            reply(true, "Always-on disabled")
        }
    }

    /// Re-apply pmset settings for a mode WITHOUT touching the always-on assertion.
    private func reapplyMode(_ mode: String) {
        switch mode {
        case "serving", "max":
            runPmset(["-a", "sleep", "0", "hibernatemode", "0"])
        default: // normal
            runPmset(["-a", "sleep", "1", "displaysleep", "10", "hibernatemode", "3"])
        }
    }

    // MARK: - Daemon Suspension

    func suspendDaemons(_ on: Bool, reply: @escaping (Bool, String) -> Void) {
        suspendNonEssentialDaemons(on)
        writeState("daemons_suspended", on ? "1" : "0")
        reply(true, on ? "Non-essential daemons suspended" : "Daemons restored")
    }

    // MARK: - Helpers

    private func runPmset(_ args: [String]) {
        let result = shell(["/usr/bin/pmset"] + args)
        if result.exitCode != 0 {
            // Log but don't fail — some settings may require different permissions
            fputs("KjolHelper: pmset failed: \(result.output)\n", stderr)
        }
    }

    /// Clear the system-wide `SleepDisabled` flag and READ IT BACK.
    ///
    /// F1/F3 hardening. `SleepDisabled` is separate from `sleep`/`displaysleep`;
    /// when another app leaves it at 1 the display cannot sleep on lid-close,
    /// silently defeating F3. `pmset -a SleepDisabled 0` is rejected as invalid
    /// syntax on some releases, so the write goes through `disablesleep 0`
    /// (the accepted spelling) and the result is verified by parsing
    /// `pmset -g`, which reports the flag under either name.
    /// (docs/RESEARCH.md A1; skill apple-silicon-smc-control.)
    ///
    /// No new Timer and no polling: this runs only on the always-on enable
    /// path, so the lightweight invariant is unaffected.
    @discardableResult
    private func assertSleepDisabledOff() -> (ok: Bool, detail: String) {
        runPmset(["-a", "disablesleep", "0"])

        let probe = shell(["/usr/bin/pmset", "-g"])
        guard probe.exitCode == 0 else {
            return (false, "pmset -g failed (exit \(probe.exitCode))")
        }

        // Match either spelling; the value is the last whitespace-separated
        // field on the line. Absent == not set == off.
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
            // Disable Spotlight indexing
            shell(["/usr/bin/mdutil", "-a", "-i", "off"])
            // Suspend non-essential daemons in one call using a regex pattern
            shell(["/usr/bin/pkill", "-STOP", "-f", pattern])
        } else {
            // Re-enable Spotlight indexing
            shell(["/usr/bin/mdutil", "-a", "-i", "on"])
            // Resume suspended daemons in one call using a regex pattern
            shell(["/usr/bin/pkill", "-CONT", "-f", pattern])
        }
    }

    // MARK: - Status

    func getStatus(reply: @escaping ([String: Any]) -> Void) {
        let mode = readState("mode")
        let alwaysOn = readState("always_on")
        let daemonsSuspended = readState("daemons_suspended")

        let status: [String: Any] = [
            "mode": mode.isEmpty ? "normal" : mode,
            "always_on": alwaysOn == "1",
            "daemons_suspended": daemonsSuspended == "1",
            "caffeinate_running": caffeinateRunning(),
            "caffeinate_pid": caffeinateRunning() ? caffeinateJobLabel : "",
            // F1/F3 read-back guard outcome from the last always-on enable.
            // Defaults to true when never recorded, so a fresh install does
            // not report a warning it has not actually observed.
            "sleep_disabled_ok": readState("sleep_disabled_ok") != "0",
            "sleep_disabled_detail": readState("sleep_disabled_detail")
        ]
        reply(status)
    }

    // MARK: - Fan Control

    func getFanStatus(reply: @escaping ([String: Any]) -> Void) {
        let fc = FanController.shared

        // Self-heal: firmware reclaims fans on sleep/wake. If a manual profile
        // is saved but a fan slipped out of manual mode, silently re-apply.
        let savedProfile = readState("fan_profile")
        if !savedProfile.isEmpty, savedProfile != "auto" {
            let pct = Double(readState("fan_rpm_percent")) ?? 0
            let slipped = fc.allFans().contains { $0.mode != 1 }
            if slipped {
                for i in 0..<fc.fanCount {
                    if let info = try? fc.fanInfo(i) {
                        let rpm = info.minRPM + Float(pct / 100.0) * (info.maxRPM - info.minRPM)
                        try? fc.setManual(i, rpm: rpm)
                    }
                }
            }
        }

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
        reply(out)
    }

    func setFanProfile(_ profile: String, rpmPercent: Double, targetTempC: Double, reply: @escaping (Bool, String) -> Void) {
        let fc = FanController.shared
        let count = fc.fanCount
        guard count > 0 else { reply(false, "No fans detected"); return }

        func percentForProfile() -> Double? {
            switch profile {
            case "auto":  return nil          // system control
            case "quiet": return 25           // low, steady airflow
            case "cool":  return 60           // strong airflow, tolerable noise
            case "blast": return 100          // max RPM
            case "custom": return max(0, min(rpmPercent, 100))
            default: return nil
            }
        }

        do {
            if profile == "targetTemp" {
                // Target-temp mode: map current SoC temp to a manual fan percentage.
                // We keep it simple and lightweight: read temp once, scale linearly
                // across a safe operating range, and set all fans manually.
                // If the SoC is already above a hard ceiling, force blast.
                let temp = fc.socTemperature() ?? 0
                let target = max(40, min(110, targetTempC))
                let minTemp: Float = 40
                let maxTemp: Float = 110
                let pct: Double
                if temp >= maxTemp {
                    pct = 100
                } else {
                    let ratio = Double(max(0, min(1, (temp - minTemp) / (maxTemp - minTemp))))
                    pct = 25 + ratio * 75 // quiet→blast across the range
                }
                let clamped = max(0, min(100, pct))
                for i in 0..<count {
                    let info = try fc.fanInfo(i)
                    let rpm = info.minRPM + Float(clamped / 100.0) * (info.maxRPM - info.minRPM)
                    try fc.setManual(i, rpm: rpm)
                }
                writeState("fan_profile", profile)
                writeState("fan_rpm_percent", String(Int(clamped)))
                reply(true, "Target-temp fan mode set (~\(Int(target))°C target)")
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
            for i in 0..<count {
                let info = try fc.fanInfo(i)
                let rpm = info.minRPM + Float(pct / 100.0) * (info.maxRPM - info.minRPM)
                try fc.setManual(i, rpm: rpm)
            }
            writeState("fan_profile", profile)
            writeState("fan_rpm_percent", String(Int(pct)))
            reply(true, "Fan profile '\(profile)' set (\(Int(pct))%)")
        } catch {
            reply(false, "Fan control failed: \(error)")
        }
    }

    // MARK: - XPC Listener

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: KjolHelperProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = {
            // Connection invalidated. Do nothing to preserve Always-On state.
        }

        newConnection.resume()
        return true
    }
}

// MARK: - Main

let listener = NSXPCListener(machServiceName: "com.lappier.kjol.helper")
let helper = KjolHelper()
listener.delegate = helper
listener.resume()

// Keep the helper running
RunLoop.current.run()
