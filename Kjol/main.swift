
import SwiftUI
import AppKit
import Foundation
import Combine
import ServiceManagement
import Security
import CoreFoundation

enum Design {
    enum Spacing {
        static let space1: CGFloat = 4
        static let space2: CGFloat = 8
        static let space3: CGFloat = 12
        static let space4: CGFloat = 16
        static let space6: CGFloat = 24
        static let space8: CGFloat = 32
        static let space12: CGFloat = 48
    }

    enum Typography {
        static let xs = Font.system(size: 12, weight: .regular)
        static let sm = Font.system(size: 14, weight: .medium)
        static let base = Font.system(size: 16, weight: .regular)
        static let lg = Font.system(size: 18, weight: .regular)
        static let xl = Font.system(size: 20, weight: .semibold)
        static let xxl = Font.system(size: 24, weight: .semibold)

        static let xsMonospaced = Font.system(size: 12, weight: .regular, design: .monospaced)
    }

    enum Color {
        static let background = SwiftUI.Color(NSColor.windowBackgroundColor)
        static let foreground = SwiftUI.Color.primary
        static let secondaryText = SwiftUI.Color.secondary
        static let tertiaryText = SwiftUI.Color.secondary.opacity(0.6)
        static let warning = SwiftUI.Color.orange
        static let accent = SwiftUI.Color.accentColor
    }

    enum Icon {
        static let inline: CGFloat = 16
        static let action: CGFloat = 20
        static let nav: CGFloat = 24
        static let feature: CGFloat = 32
        static let hero: CGFloat = 48
    }
}


struct HostState: Equatable {
    var alwaysOn: Bool = false
    var caffeinateRunning: Bool = false
    var caffeinatePID: String = ""
    var sleepDisabledOK: Bool = true
    var sleepDisabledDetail: String = ""
    var daemonsSuspended: Bool = false
    var busy: Bool = false
    var errorMessage: String?
    var lastUpdated: Date = Date()
}


enum FanProfile: String, CaseIterable, Identifiable {
    case auto, quiet, balanced, blast, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .blast: return "Blast"
        case .custom: return "Custom"
        }
    }
    var icon: String {
        switch self {
        case .auto: return "gearshape"
        case .quiet: return "moon"
        case .balanced: return "chart.line.uptrend.xyaxis"
        case .blast: return "hurricane"
        case .custom: return "slider.horizontal.3"
        }
    }
}

struct FanReading: Equatable, Identifiable {
    var index: Int
    var actualRPM: Double
    var targetRPM: Double
    var minRPM: Double
    var maxRPM: Double
    var mode: Int
    var id: Int { index }
    var percent: Double {
        guard maxRPM > minRPM else { return 0 }
        return max(0, min(1, (actualRPM - minRPM) / (maxRPM - minRPM)))
    }
}

struct FanState: Equatable {
    var fans: [FanReading] = []
    var socTemp: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var profile: FanProfile = .auto
    var customPercent: Double = 50
    var history: [[Double]] = []
    var tempHistory: [Double] = []
}

struct BatteryState: Equatable {
    var chargePercent: Int = 0
    var isCharging: Bool = false
    var externalConnected: Bool = false
    var cycleCount: Int = 0
    var temperature: Double = 0
    var limit: Int = 80
    var limitEnabled: Bool = false
}

struct CpuState: Equatable {
    var perCore: [Double] = []
    var pCoreCount: Int = 0
    var eCoreCount: Int = 0
    var pCoreUsage: Double = 0
    var eCoreUsage: Double = 0
    var overallUsage: Double = 0
    var hasSample = false
}

final class CpuSampler {
    private var prevTotal: [UInt32] = []
    private var prevBusy: [UInt32] = []
    private let cachedPCoreCount: Int
    private let cachedECoreCount: Int

    init() {
        var pCount: Int = 0
        var eCount: Int = 0
        var sz = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &pCount, &sz, nil, 0)
        sz = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel1.logicalcpu", &eCount, &sz, nil, 0)
        cachedPCoreCount = pCount
        cachedECoreCount = eCount
    }

    func sample() -> CpuState {
        var state = CpuState()
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return state }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.size)) }

        let loads = UnsafeBufferPointer<processor_cpu_load_info>(
            start: UnsafeRawPointer(info).assumingMemoryBound(to: processor_cpu_load_info.self),
            count: Int(numCPUs))

        var total: [UInt32] = [], busy: [UInt32] = []
        for i in 0..<Int(numCPUs) {
            let t = loads[i].cpu_ticks
            let u = t.0
            let s = t.1
            let idle = t.2
            let n = t.3
            total.append(u &+ s &+ idle &+ n)
            busy.append(u &+ s &+ n)
        }
        if prevTotal.count == total.count {
            for i in 0..<total.count {
                let dTot = max(1, Double(total[i] &- prevTotal[i]))
                let dBsy = max(0, Double(busy[i] &- prevBusy[i]))
                state.perCore.append(dBsy / dTot)
            }
            state.hasSample = true

            if cachedPCoreCount > 0, state.perCore.count >= cachedPCoreCount {
                let pUsages = state.perCore.prefix(cachedPCoreCount)
                state.pCoreUsage = pUsages.reduce(0, +) / Double(pUsages.count)

                let eUsages = state.perCore.dropFirst(cachedPCoreCount)
                if !eUsages.isEmpty {
                    state.eCoreUsage = eUsages.reduce(0, +) / Double(eUsages.count)
                }
            } else if !state.perCore.isEmpty {
                state.pCoreUsage = state.perCore.reduce(0, +) / Double(state.perCore.count)
            }
            if !state.perCore.isEmpty {
                state.overallUsage = state.perCore.reduce(0, +) / Double(state.perCore.count)
            }
        }
        prevTotal = total
        prevBusy = busy

        state.pCoreCount = cachedPCoreCount
        state.eCoreCount = cachedECoreCount
        return state
    }
}


final class HelperClient {
    private var connection: NSXPCConnection?

    func connect() {
        connection = NSXPCConnection(machServiceName: "com.lappier.kjol.helper",
                                     options: .privileged)
        connection?.remoteObjectInterface = NSXPCInterface(with: KjolHelperProtocol.self)
        connection?.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        connection?.resume()
    }

    func setAlwaysOn(_ on: Bool, completion: @escaping (Bool, String) -> Void) {
        guard let proxy = remoteProxy() else {
            completion(false, "Helper not connected")
            return
        }
        proxy.setAlwaysOn(on) { success, message in
            DispatchQueue.main.async { completion(success, message) }
        }
    }

    func syncSetAlwaysOn(_ on: Bool) {
        guard let proxy = remoteProxy() else {
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        proxy.setAlwaysOn(on) { _, _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
    }

    func suspendDaemons(_ on: Bool, completion: @escaping (Bool, String) -> Void) {
        guard let proxy = remoteProxy() else {
            completion(false, "Helper not connected")
            return
        }
        proxy.suspendDaemons(on) { success, message in
            DispatchQueue.main.async { completion(success, message) }
        }
    }

    func getStatus(completion: @escaping ([String: Any]) -> Void) {
        guard let proxy = remoteProxy() else {
            completion([:])
            return
        }
        proxy.getStatus { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    func getFanStatus(completion: @escaping ([String: Any]) -> Void) {
        guard let proxy = remoteProxy() else {
            completion([:])
            return
        }
        proxy.getFanStatus { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    func setFanProfile(_ profile: String, rpmPercent: Double, targetTempC: Double, completion: @escaping (Bool, String) -> Void) {
        guard let proxy = remoteProxy() else {
            completion(false, "Helper not connected")
            return
        }
        proxy.setFanProfile(profile, rpmPercent: rpmPercent, targetTempC: targetTempC) { success, message in
            DispatchQueue.main.async { completion(success, message) }
        }
    }

    func setBatteryLimit(_ limit: Int, enabled: Bool, completion: @escaping (Bool, String) -> Void) {
        guard let proxy = remoteProxy() else {
            completion(false, "Helper not connected")
            return
        }
        proxy.setBatteryLimit(limit, enabled: enabled) { success, message in
            DispatchQueue.main.async { completion(success, message) }
        }
    }

    func getBatteryStatus(completion: @escaping ([String: Any]) -> Void) {
        guard let proxy = remoteProxy() else {
            completion([:])
            return
        }
        proxy.getBatteryStatus { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    private func remoteProxy() -> KjolHelperProtocol? {
        if connection == nil {
            connect()
        }
        return connection?.remoteObjectProxy as? KjolHelperProtocol
    }
}


final class Host: ObservableObject {
    @Published var state = HostState()
    @Published var fanState = FanState()
    @Published var cpuState = CpuState()
    @Published var batteryState = BatteryState()
    @Published var helperInstalled = false

    private let helper = HelperClient()
    private let cpuSampler = CpuSampler()
    private var timer: Timer?

    init() {
        helper.connect()
        checkHelperInstalled()
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    func startPolling(interval: TimeInterval = 3.0) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = interval * 0.5
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }


    func setAlwaysOn(_ on: Bool) {
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        helper.setAlwaysOn(on) { [weak self] success, message in
            guard let self = self else { return }
            self.state.busy = false
            if !success {
                self.state.errorMessage = message
            }
            self.refresh()
        }
    }

    func setDaemonsSuspended(_ on: Bool) {
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        helper.suspendDaemons(on) { [weak self] success, message in
            guard let self = self else { return }
            self.state.busy = false
            if !success {
                self.state.errorMessage = message
            }
            self.refresh()
        }
    }

    func setFanProfile(_ profile: FanProfile, customPercent: Double? = nil) {
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        let pct = customPercent ?? fanState.customPercent
        helper.setFanProfile(profile.rawValue, rpmPercent: pct, targetTempC: 0) { [weak self] success, message in
            guard let self = self else { return }
            self.state.busy = false
            if !success {
                self.state.errorMessage = message
            }
            self.refreshFans()
        }
    }

    func setBatteryLimit(_ limit: Int, enabled: Bool) {
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        helper.setBatteryLimit(limit, enabled: enabled) { [weak self] success, message in
            guard let self = self else { return }
            self.state.busy = false
            if !success {
                self.state.errorMessage = message
            }
            self.refreshBattery()
        }
    }

    func syncSetAlwaysOn(_ on: Bool) {
        helper.syncSetAlwaysOn(on)
    }

    func installHelper() {
        state.busy = true
        state.errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if #available(macOS 13.0, *) {
                let daemonService = SMAppService.daemon(plistName: "com.lappier.kjol.helper.plist")
                let mainAppService = SMAppService.mainApp

                var errors: [String] = []

                if mainAppService.status != .enabled {
                    do {
                        try mainAppService.register()
                    } catch {
                        errors.append("Login item registration failed: \(error.localizedDescription)")
                    }
                }

                if daemonService.status != .enabled {
                    do {
                        try daemonService.register()
                    } catch {
                        let nsErr = error as NSError
                        if nsErr.code == -60005 || nsErr.localizedDescription.contains("canceled") || nsErr.localizedDescription.contains("cancelled") {
                            errors.append("Admin authorization was cancelled or denied.")
                        } else {
                            self.installHelperManual()
                            return
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.state.busy = false
                    self.checkHelperInstalled()
                    if !errors.isEmpty {
                        self.state.errorMessage = errors.joined(separator: " ")
                    } else if daemonService.status == .requiresApproval {
                        self.state.errorMessage = "Helper requires approval in System Settings → General → Login Items & Extensions."
                    } else if daemonService.status == .denied {
                        self.state.errorMessage = "Helper background activity is denied in System Settings."
                    } else if self.helperInstalled {
                        self.refresh()
                    }
                }
            } else {
                self.installHelperManual()
            }
        }
    }

    func installHelperManual() {
        let bundlePath = Bundle.main.bundlePath
        let srcBin = "\(bundlePath)/Contents/Library/LaunchDaemons/com.lappier.kjol.helper"
        let tmpPlist = "\(bundlePath)/Contents/Library/LaunchDaemons/com.lappier.kjol.helper.plist"
        let dstBin = "/Library/PrivilegedHelperTools/com.lappier.kjol.helper"
        let dstPlist = "/Library/LaunchDaemons/com.lappier.kjol.helper.plist"

        let privilegedCommands = """
        /bin/launchctl bootout system/com.lappier.kjol.helper 2>/dev/null || true
        /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons /var/log
        /bin/cp '\(srcBin)' '\(dstBin)'
        /usr/sbin/chown root:wheel '\(dstBin)'
        /bin/chmod 755 '\(dstBin)'
        /bin/cp '\(tmpPlist)' '\(dstPlist)'
        /usr/sbin/chown root:wheel '\(dstPlist)'
        /bin/chmod 644 '\(dstPlist)'
        /bin/launchctl bootstrap system '\(dstPlist)'
        /bin/launchctl enable system/com.lappier.kjol.helper || true
        """

        let osascriptCmd = """
        do shell script "\(privilegedCommands)" with administrator privileges
        """

        var authFailed = false
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", osascriptCmd]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            if let data = try? pipe.fileHandleForReading.readToEnd(),
               let output = String(data: data, encoding: .utf8),
               (output.contains("execution error") || output.contains("User canceled")) {
                authFailed = true
            }
        } catch {
            authFailed = true
        }

        DispatchQueue.main.async {
            self.state.busy = false
            self.checkHelperInstalled()
            if authFailed {
                self.state.errorMessage = "Admin authorization was cancelled or failed for manual helper installation."
            } else if self.helperInstalled {
                self.refresh()
            } else {
                self.state.errorMessage = "Manual helper installation failed."
            }
        }
    }


    func refresh() {
        helper.getStatus { [weak self] status in
            guard let self = self else { return }

            let new = HostState(
                alwaysOn: status["always_on"] as? Bool ?? false,
                caffeinateRunning: status["caffeinate_running"] as? Bool ?? false,
                caffeinatePID: status["caffeinate_pid"] as? String ?? "",
                sleepDisabledOK: status["sleep_disabled_ok"] as? Bool ?? true,
                sleepDisabledDetail: status["sleep_disabled_detail"] as? String ?? "",
                daemonsSuspended: status["daemons_suspended"] as? Bool ?? false,
                busy: self.state.busy,
                errorMessage: self.state.errorMessage,
                lastUpdated: Date()
            )
            if self.state != new { self.state = new }
        }
        refreshFans()
        refreshBattery()

        let cpu = cpuSampler.sample()
        if cpuState != cpu { cpuState = cpu }
    }

    func refreshFans() {
        helper.getFanStatus { [weak self] status in
            guard let self = self else { return }
            guard let raw = status["fans"] as? [[Double]] else { return }
            let fans = raw.compactMap { a -> FanReading? in
                guard a.count >= 6 else { return nil }
                return FanReading(index: Int(a[0]), actualRPM: a[1], targetRPM: a[2],
                                  minRPM: a[3], maxRPM: a[4], mode: Int(a[5]))
            }
            var fs = FanState()
            fs.fans = fans
            fs.socTemp = status["socTemp"] as? Double
            fs.cpuTemp = status["cpuTemp"] as? Double
            fs.gpuTemp = status["gpuTemp"] as? Double
            if let p = status["profile"] as? String, let prof = FanProfile(rawValue: p) {
                fs.profile = prof
            }
            if let pct = status["rpmPercent"] as? Double, pct > 0, fs.profile == .custom {
                fs.customPercent = pct
            }
            if self.fanState.history.count == fans.count, !fans.isEmpty {
                fs.history = self.fanState.history
                fs.tempHistory = self.fanState.tempHistory
                for (i, f) in fans.enumerated() {
                    fs.history[i].append(f.actualRPM)
                    if fs.history[i].count > 60 { fs.history[i].removeFirst() }
                }
                fs.tempHistory.append(fs.socTemp ?? 0)
                if fs.tempHistory.count > 60 { fs.tempHistory.removeFirst() }
            }
            if self.fanState != fs { self.fanState = fs }
        }
    }

    func refreshBattery() {
        helper.getBatteryStatus { [weak self] status in
            guard let self = self else { return }
            var bs = BatteryState()
            bs.chargePercent = status["chargePercent"] as? Int ?? 0
            bs.isCharging = status["isCharging"] as? Bool ?? false
            bs.externalConnected = status["externalConnected"] as? Bool ?? false
            bs.cycleCount = status["cycleCount"] as? Int ?? 0
            bs.temperature = status["temperature"] as? Double ?? 0
            bs.limit = status["limit"] as? Int ?? 80
            bs.limitEnabled = status["enabled"] as? Bool ?? false
            if self.batteryState != bs { self.batteryState = bs }
        }
    }

    func checkHelperInstalled() {
        if #available(macOS 13.0, *) {
            let daemonService = SMAppService.daemon(plistName: "com.lappier.kjol.helper.plist")
            helperInstalled = (daemonService.status == .enabled)
        } else {
            let plist = "/Library/LaunchDaemons/com.lappier.kjol.helper.plist"
            let bin = "/Library/PrivilegedHelperTools/com.lappier.kjol.helper"
            helperInstalled = FileManager.default.fileExists(atPath: plist)
                && FileManager.default.fileExists(atPath: bin)
        }
    }
}


private func kjolQuit() {
    NSApplication.shared.terminate(nil)
}

struct KjolView: View {
    @EnvironmentObject var host: Host
    @State private var showDetails: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space3) {
            headerView
            overviewMetricsPanel
            if showDetails {
                detailedTelemetryPanel
            }
            controlsView
            Spacer(minLength: 0)
            footerView
        }
        .padding(Design.Spacing.space4)
        .frame(width: 380, height: 550)
        .background(Design.Color.background)
    }

    private var headerView: some View {
        HStack(spacing: Design.Spacing.space2) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Design.Color.accent)
            Text("Kjol")
                .font(Design.Typography.base)
                .fontWeight(.bold)
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .opacity(host.state.busy ? 1 : 0)
        }
    }

    private var overviewMetricsPanel: some View {
        VStack(spacing: Design.Spacing.space2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overall Temp")
                        .font(Design.Typography.xs)
                        .foregroundStyle(Design.Color.secondaryText)
                    Text(overallTempDisplay)
                        .font(Design.Typography.xl)
                        .fontWeight(.bold)
                        .foregroundStyle(Design.Color.foreground)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("CPU Load")
                        .font(Design.Typography.xs)
                        .foregroundStyle(Design.Color.secondaryText)
                    Text(cpuLoadDisplay)
                        .font(Design.Typography.xl)
                        .fontWeight(.bold)
                        .foregroundStyle(Design.Color.foreground)
                }
            }

            Button(action: { showDetails.toggle() }) {
                HStack(spacing: Design.Spacing.space1) {
                    Text(showDetails ? "Hide Telemetry Details" : "Show Granular Telemetry")
                        .font(Design.Typography.xs)
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Design.Color.accent)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(Design.Spacing.space3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var detailedTelemetryPanel: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space2) {
            Group {
                HStack {
                    Text("SoC: \(socTempDisplay)")
                    Spacer()
                    Text("CPU: \(cpuTempDisplay)")
                    Spacer()
                    Text("GPU: \(gpuTempDisplay)")
                }
                .font(Design.Typography.xsMonospaced)
                .foregroundStyle(Design.Color.secondaryText)

                HStack {
                    Text("P-Cores (\(host.cpuState.pCoreCount)): \(pCoreDisplay)")
                    Spacer()
                    Text("E-Cores (\(host.cpuState.eCoreCount)): \(eCoreDisplay)")
                }
                .font(Design.Typography.xsMonospaced)
                .foregroundStyle(Design.Color.secondaryText)

                HStack {
                    Text("Fans: \(fansDisplay)")
                    Spacer()
                    Text("Battery: \(batteryDisplay)")
                }
                .font(Design.Typography.xsMonospaced)
                .foregroundStyle(Design.Color.secondaryText)
            }
        }
        .padding(Design.Spacing.space3)
        .background(Design.Color.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(height: 70)
    }

    private var controlsView: some View {
        VStack(spacing: Design.Spacing.space3) {
            if !host.helperInstalled {
                VStack(spacing: Design.Spacing.space3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Design.Icon.nav))
                        .foregroundStyle(Design.Color.warning)
                    Text("Kjol needs a privileged helper to manage system power and battery settings.")
                        .font(Design.Typography.xs)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Design.Color.secondaryText)
                    Button("Install Helper") {
                        host.installHelper()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                controlGroup(label: "Fan Control Strategy") {
                    Picker("", selection: $host.fanState.profile) {
                        ForEach(FanProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(host.state.busy)
                    .onChange(of: host.fanState.profile) {
                        host.setFanProfile(host.fanState.profile)
                    }

                    if host.fanState.profile == .custom {
                        fanSlider(
                            title: "Custom Speed",
                            value: $host.fanState.customPercent,
                            unit: "%",
                            range: 0...100,
                            step: 5,
                            onChange: { host.setFanProfile(.custom, customPercent: $0) }
                        )
                    }
                }

                controlGroup(label: "Battery Health Management") {
                    VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                        HStack {
                            Toggle("Charge Limit", isOn: Binding(
                                get: { host.batteryState.limitEnabled },
                                set: { host.setBatteryLimit(host.batteryState.limit, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .disabled(host.state.busy)

                            Spacer()

                            if host.batteryState.limitEnabled {
                                Text("Limit: \(host.batteryState.limit)%")
                                    .font(Design.Typography.xsMonospaced)
                                    .foregroundStyle(Design.Color.secondaryText)
                            }
                        }

                        if host.batteryState.limitEnabled {
                            Slider(
                                value: Binding(
                                    get: { Double(host.batteryState.limit) },
                                    set: { host.setBatteryLimit(Int($0), enabled: true) }
                                ),
                                in: 50...90,
                                step: 5
                            )
                            .disabled(host.state.busy)
                        }
                    }
                }

                controlGroup(label: "System Power & Clamshell") {
                    HStack {
                        Toggle("Always-On (Clamshell)", isOn: Binding(
                            get: { host.state.alwaysOn },
                            set: { host.setAlwaysOn($0) }
                        ))
                        .toggleStyle(.switch)
                        .disabled(host.state.busy)

                        Spacer()
                    }
                }

                controlGroup(label: "Background Efficiency") {
                    HStack {
                        Toggle("Pause Indexing Daemons", isOn: Binding(
                            get: { host.state.daemonsSuspended },
                            set: { host.setDaemonsSuspended($0) }
                        ))
                        .toggleStyle(.switch)
                        .disabled(host.state.busy)

                        Spacer()
                    }
                }
            }
        }
    }

    private var footerView: some View {
        VStack(spacing: Design.Spacing.space1) {
            if let err = host.state.errorMessage, !err.isEmpty {
                Text(err)
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            HStack {
                Button("Quit Kjol", action: kjolQuit)
                    .buttonStyle(.plain)
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                Spacer(minLength: 0)
                if !host.helperInstalled {
                    Text("Helper Not Installed")
                        .font(Design.Typography.xs)
                        .foregroundStyle(Design.Color.warning)
                } else {
                    Text("Helper Active")
                        .font(Design.Typography.xs)
                        .foregroundStyle(Design.Color.tertiaryText)
                }
            }
        }
    }

    private func controlGroup(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space1) {
            Text(label)
                .font(Design.Typography.xs)
                .foregroundStyle(Design.Color.tertiaryText)
            content()
        }
    }

    private func fanSlider(title: String, value: Binding<Double>, unit: String, range: ClosedRange<Double>, step: Double, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space1) {
            HStack(spacing: Design.Spacing.space2) {
                Text(title)
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.tertiaryText)
                    .frame(width: 80, alignment: .leading)
                Slider(value: value, in: range, step: step) { editing in
                    if !editing {
                        onChange(value.wrappedValue)
                    }
                }
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(Design.Typography.xsMonospaced)
                    .foregroundStyle(Design.Color.tertiaryText)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 2)
    }

    private var overallTempDisplay: String {
        let soc = host.fanState.socTemp ?? 0
        let cpu = host.fanState.cpuTemp ?? 0
        let gpu = host.fanState.gpuTemp ?? 0
        let maxVal = max(soc, max(cpu, gpu))
        return maxVal > 0 ? String(format: "%.0f°C", maxVal) : "—"
    }

    private var cpuLoadDisplay: String {
        guard host.cpuState.hasSample else { return "—" }
        return String(format: "%.0f%%", host.cpuState.overallUsage * 100)
    }

    private var socTempDisplay: String {
        if let t = host.fanState.socTemp { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var cpuTempDisplay: String {
        if let t = host.fanState.cpuTemp { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var gpuTempDisplay: String {
        if let t = host.fanState.gpuTemp { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var pCoreDisplay: String {
        guard host.cpuState.hasSample else { return "—" }
        return String(format: "%.0f%%", host.cpuState.pCoreUsage * 100)
    }

    private var eCoreDisplay: String {
        guard host.cpuState.hasSample else { return "—" }
        return String(format: "%.0f%%", host.cpuState.eCoreUsage * 100)
    }

    private var fansDisplay: String {
        if host.fanState.fans.isEmpty { return "—" }
        return host.fanState.fans.map { "\(Int($0.actualRPM)) RPM" }.joined(separator: " / ")
    }

    private var batteryDisplay: String {
        let pct = host.batteryState.chargePercent
        let status = host.batteryState.isCharging ? "⚡" : ""
        let cycles = host.batteryState.cycleCount
        return "\(pct)%\(status) (\(cycles) cycles)"
    }
}


class KjolHostingController<Content: View>: NSHostingController<Content> {
    weak var statusButton: NSStatusBarButton?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private let host = Host()
    private var popoverShown = false {
        didSet { updatePolling() }
    }
    private var cancellables = Set<AnyCancellable>()

    private func updateStatusItemIcon() {
        let fanManual = host.fanState.profile != .auto
        let imageName: String
        if let err = host.state.errorMessage, !err.isEmpty {
            imageName = "exclamationmark.octagon.fill"
        } else if host.state.busy {
            imageName = "bolt.horizontal.icloud.fill"
        } else if fanManual {
            imageName = "fan.fill"
        } else {
            imageName = "bolt"
        }
        statusItem.button?.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Kjol")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.contentTintColor = host.state.alwaysOn ? .controlAccentColor : nil
        var tip = "Kjol"
        if let t = host.fanState.socTemp { tip += String(format: " · %.0f°C", t) }
        if !host.fanState.fans.isEmpty {
            let rpms = host.fanState.fans.map { "\(Int($0.actualRPM))" }.joined(separator: "/")
            tip += " · \(rpms) rpm"
        }
        if host.state.alwaysOn { tip += " · Always-On" }
        if let err = host.state.errorMessage, !err.isEmpty { tip += " · \(err)" }
        statusItem.button?.toolTip = tip
    }

    private func updatePolling() {
        if popoverShown {
            host.refresh()
            host.startPolling(interval: 3.0)
        } else {
            host.stopPolling()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } catch {
                print("Failed to register SMAppService: \(error)")
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: "Kjol")
            btn.image?.isTemplate = true
            btn.action = #selector(togglePopover(_:))
            btn.target = self
        }

        updateStatusItemIcon()
        host.$state
            .dropFirst()
            .sink { [weak self] _ in self?.updateStatusItemIcon() }
            .store(in: &cancellables)
        updatePolling()
    }

    private func buildPopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        let controller = KjolHostingController(rootView: KjolView().environmentObject(host))
        controller.statusButton = statusItem.button
        p.contentViewController = controller
        return p
    }

    @objc func togglePopover(_ sender: Any?) {
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
            popoverShown = false
            return
        }
        let pop = popover ?? buildPopover()
        popover = pop
        if let btn = statusItem.button {
            pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .maxY)
            pop.animates = false
            if let window = pop.contentViewController?.view.window {
                window.animationBehavior = .none
            }
        }
        popoverShown = true
    }

    func popoverDidClose(_ notification: Notification) {
        popoverShown = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if host.state.alwaysOn {
            host.syncSetAlwaysOn(false)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
