import Foundation
import Combine
import SwiftUI

final class Host: ObservableObject {
    @Published var helperInstalled: Bool = false
    @Published var busy: Bool = false
    @Published var errorMessage: String?

    let telemetryVM = TelemetryViewModel()
    let fanControlVM = FanControlViewModel()
    let powerVM = PowerViewModel()

    private let xpcClient = XpcClient()
    private let cpuSampler = CpuSamplerService()
    private let helperInstaller = HelperInstaller()
    private var pollingTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.lappier.kjol.polling", qos: .utility)

    init() {
        xpcClient.onReconnect = { [weak self] in
            self?.refresh()
        }
        setupViewModelCallbacks()
        xpcClient.connect()
        checkHelperInstalled()
        refresh()
    }

    deinit {
        stopPolling()
    }

    private func setupViewModelCallbacks() {
        fanControlVM.onProfileChange = { [weak self] profile, pct in
            self?.setFanProfile(profile, customPercent: pct)
        }
        powerVM.onAlwaysOnToggle = { [weak self] on in
            self?.setAlwaysOn(on)
        }
        powerVM.onDaemonsToggle = { [weak self] on in
            self?.setDaemonsSuspended(on)
        }
        powerVM.onBatteryLimitChange = { [weak self] limit, enabled in
            self?.setBatteryLimit(limit, enabled: enabled)
        }
    }

    func checkHelperInstalled() {
        helperInstalled = HelperInstaller.isHelperInstalled()
    }

    func installHelper() {
        busy = true
        errorMessage = nil
        helperInstaller.install { [weak self] success, err in
            guard let self = self else { return }
            self.busy = false
            if success {
                self.helperInstalled = true
                self.refresh()
            } else {
                self.errorMessage = err ?? "Helper installation failed"
            }
        }
    }

    func startPolling(interval: TimeInterval = 3.0) {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let leeway = DispatchTimeInterval.milliseconds(Int(interval * 500))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Kjol Telemetry Polling"
            )
            self?.refresh()
            ProcessInfo.processInfo.endActivity(activity)
        }
        pollingTimer = timer
        timer.resume()
    }

    func stopPolling() {
        pollingTimer?.cancel()
        pollingTimer = nil
    }

    func refresh() {
        Task {
            do {
                let status = try await xpcClient.getCombinedStatus()
                let battery = try await xpcClient.getBatteryStatus()
                let cpu = cpuSampler.sample()

                let hostDict = status["host"] as? [String: Any] ?? [:]
                let fansDict = status["fans"] as? [String: Any] ?? [:]

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.telemetryVM.updateTelemetry(cpu: cpu, fansDict: fansDict, batteryDict: battery)
                    self.powerVM.updateHostState(hostDict: hostDict)
                    self.powerVM.updateBatteryState(batteryDict: battery)
                    self.fanControlVM.updateFromDaemon(
                        profileString: fansDict["profile"] as? String,
                        rpmPercent: fansDict["rpmPercent"] as? Double
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func setAlwaysOn(_ on: Bool) {
        performAction { [weak self] in
            _ = try await self?.xpcClient.setAlwaysOn(on)
        }
    }

    func syncSetAlwaysOn(_ on: Bool) {
        xpcClient.syncSetAlwaysOn(on)
    }

    func setDaemonsSuspended(_ on: Bool) {
        performAction { [weak self] in
            _ = try await self?.xpcClient.suspendDaemons(on)
        }
    }

    func setFanProfile(_ profile: FanProfile, customPercent: Double? = nil) {
        let pct = customPercent ?? fanControlVM.customPercent
        performAction { [weak self] in
            _ = try await self?.xpcClient.setFanProfile(profile.rawValue, rpmPercent: pct)
        }
    }

    func setBatteryLimit(_ limit: Int, enabled: Bool) {
        performAction { [weak self] in
            _ = try await self?.xpcClient.setBatteryLimit(limit, enabled: enabled)
        }
    }

    private func performAction(_ block: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                try await block()
                DispatchQueue.main.async { [weak self] in
                    self?.busy = false
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.busy = false
                    self?.errorMessage = error.localizedDescription
                    self?.refresh()
                }
            }
        }
    }
}
