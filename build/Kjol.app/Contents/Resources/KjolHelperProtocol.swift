// KjolHelperProtocol.swift
// XPC protocol shared between the Kjol app and the Kjol Helper.
// This file is compiled into both targets.

import Foundation

@objc(KjolHelperProtocol)
protocol KjolHelperProtocol {
    /// Set the system power mode: "normal", "serving", or "max"
    func setPowerMode(_ mode: String, reply: @escaping (Bool, String) -> Void)

    /// Enable or disable always-on (system stays awake with lid closed)
    func setAlwaysOn(_ on: Bool, reply: @escaping (Bool, String) -> Void)

    /// Suspend or resume non-essential background daemons
    func suspendDaemons(_ on: Bool, reply: @escaping (Bool, String) -> Void)

    /// Get the current status of all Kjol settings
    func getStatus(reply: @escaping ([String: Any]) -> Void)

    // MARK: Fan control

    /// Get fan telemetry: count, per-fan actual/target/min/max RPM, mode, SoC temp.
    /// Reply dict: {"fanCount": Int, "socTemp": Float,
    ///              "fans": [[index, actual, target, min, max, mode], ...]}
    func getFanStatus(reply: @escaping ([String: Any]) -> Void)

    /// Set a fan profile: "auto" | "quiet" | "cool" | "blast" | "custom" | "targetTemp".
    /// For "custom", rpmPercent (0-100) maps linearly min→max RPM per fan.
    /// For "targetTemp", targetTempC is the desired max SoC temp in °C.
    func setFanProfile(_ profile: String, rpmPercent: Double, targetTempC: Double, reply: @escaping (Bool, String) -> Void)
}
