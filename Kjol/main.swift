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
        static let xs = Font.system(size: 11, weight: .regular)
        static let sm = Font.system(size: 13, weight: .medium)
        static let base = Font.system(size: 15, weight: .semibold)
        static let lg = Font.system(size: 18, weight: .bold)

        static let xsMono = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let smMono = Font.system(size: 13, weight: .medium, design: .monospaced)
    }

    enum Color {
        static let background = SwiftUI.Color(NSColor.windowBackgroundColor)
        static let cardBackground = SwiftUI.Color(NSColor.controlBackgroundColor)
        static let foreground = SwiftUI.Color.primary
        static let secondaryText = SwiftUI.Color.secondary
        static let tertiaryText = SwiftUI.Color.secondary.opacity(0.6)
        static let warning = SwiftUI.Color.orange
        static let accent = SwiftUI.Color.accentColor
    }

    enum Icon {
        static let inline: CGFloat = 14
        static let action: CGFloat = 18
        static let nav: CGFloat = 22
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
}

struct FanReading: Equatable, Identifiable {
    var index: Int
    var actualRPM: Double
    var targetRPM: Double
    var minRPM: Double
    var maxRPM: Double
    var mode: Int
    var id: Int { index }
}

struct FanState: Equatable {
    var fans: [FanReading] = []
    var socTemp: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var profile: FanProfile = .auto
    var customPercent: Double = 50
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
        guard let proxy = remoteProxy() else { return }
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
                let service = SMAppService.daemon(plistName: "com.lappier.kjol.helper.plist")
                if service.status == .enabled {
                    DispatchQueue.main.async {
                        self.state.busy = false
                        self.helperInstalled = true
                        self.refresh()
                    }
                    return
                }
                do {
                    try service.register()
                    DispatchQueue.main.async {
                        self.state.busy = false
                        self.helperInstalled = true
                        self.refresh()
                    }
                    return
                } catch {
                    DispatchQueue.main.async {
                        self.state.busy = false
                        self.state.errorMessage = "SMAppService install failed (\(error.localizedDescription)); falling back to manual install."
                    }
                }
            }

            self.installHelperManual()
        }
    }

    func installHelperManual() {
        state.busy = true
        state.errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let bundlePath = Bundle.main.bundlePath
            let srcBin = "\(bundlePath)/Contents/Library/LaunchDaemons/com.lappier.kjol.helper"
            let dstBin = "/Library/PrivilegedHelperTools/com.lappier.kjol.helper"
            let dstPlist = "/Library/LaunchDaemons/com.lappier.kjol.helper.plist"

            guard FileManager.default.fileExists(atPath: srcBin) else {
                DispatchQueue.main.async {
                    self.state.busy = false
                    self.state.errorMessage = "Helper binary missing from app bundle"
                }
                return
            }

            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.lappier.kjol.helper</string>
                <key>ProgramArguments</key><array><string>\(dstBin)</string></array>
                <key>MachServices</key><dict><key>com.lappier.kjol.helper</key><true/></dict>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><true/>
                <key>ThrottleInterval</key><integer>30</integer>
                <key>StandardOutPath</key><string>/var/log/kjol-helper.out.log</string>
                <key>StandardErrorPath</key><string>/var/log/kjol-helper.err.log</string>
            </dict>
            </plist>
            """

            let tmpPlist = NSTemporaryDirectory() + "com.lappier.kjol.helper.plist"
            do {
                try plistContent.write(toFile: tmpPlist, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    self.state.busy = false
                    self.state.errorMessage = "Could not stage helper plist: \(error.localizedDescription)"
                }
                return
            }

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
            } catch {
                authFailed = true
            }
            if let data = try? pipe.fileHandleForReading.readToEnd(),
               let output = String(data: data, encoding: .utf8),
               (output.contains("execution error") || output.contains("User canceled")) {
                authFailed = true
            }

            try? FileManager.default.removeItem(atPath: tmpPlist)

            DispatchQueue.main.async {
                self.state.busy = false
                if authFailed {
                    self.state.errorMessage = "Helper installation requires admin approval."
                } else {
                    self.helperInstalled = true
                    self.refresh()
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

struct CardContainer<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space2) {
            Text(title)
                .font(Design.Typography.xs)
                .foregroundStyle(Design.Color.tertiaryText)
            content
        }
        .padding(Design.Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Color.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct KjolView: View {
    @EnvironmentObject var host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space3) {
            headerView
            telemetryCard
            if !host.helperInstalled {
                helperMissingCard
            } else {
                fanControlCard
                powerBatteryCard
            }
            Spacer(minLength: 0)
            footerView
        }
        .padding(Design.Spacing.space4)
        .frame(width: 360, height: 490)
        .background(Design.Color.background)
    }

    private var headerView: some View {
        HStack(spacing: Design.Spacing.space2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: Design.Icon.action))
                .foregroundStyle(Design.Color.accent)
            Text("Kjol")
                .font(Design.Typography.base)
            Spacer(minLength: 0)
            if host.state.busy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(host.helperInstalled ? "Active" : "Helper Required")
                .font(Design.Typography.xs)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    host.helperInstalled ? Design.Color.accent.opacity(0.15) : Design.Color.warning.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(host.helperInstalled ? Design.Color.accent : Design.Color.warning)
        }
    }

    private var telemetryCard: some View {
        CardContainer(title: "System Telemetry") {
            VStack(spacing: Design.Spacing.space2) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Design.Spacing.space1) {
                        metricRow(label: "SoC Temp", value: socTempDisplay)
                        metricRow(label: "CPU Temp", value: cpuTempDisplay)
                        metricRow(label: "GPU Temp", value: gpuTempDisplay)
                    }
                    Spacer(minLength: Design.Spacing.space2)
                    VStack(alignment: .leading, spacing: Design.Spacing.space1) {
                        metricRow(label: "P-Cores (\(host.cpuState.pCoreCount))", value: pCoreDisplay)
                        metricRow(label: "E-Cores (\(host.cpuState.eCoreCount))", value: eCoreDisplay)
                        metricRow(label: "Fan Speed", value: fansDisplay)
                    }
                }
                Divider()
                HStack {
                    metricRow(label: "Battery Charge", value: batteryDisplay)
                    Spacer()
                    metricRow(label: "Cycle Count", value: batteryCyclesDisplay)
                }
            }
        }
    }

    private var helperMissingCard: some View {
        CardContainer(title: "Privileged Helper") {
            VStack(spacing: Design.Spacing.space2) {
                Text("Kjol requires a background helper daemon to manage SMC hardware keys and system power policies.")
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install Helper") {
                    host.installHelper()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var fanControlCard: some View {
        CardContainer(title: "Fan Control Strategy") {
            VStack(alignment: .leading, spacing: Design.Spacing.space2) {
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

                VStack {
                    if host.fanState.profile == .custom {
                        HStack(spacing: Design.Spacing.space2) {
                            Text("Speed")
                                .font(Design.Typography.xs)
                                .foregroundStyle(Design.Color.secondaryText)
                            Slider(
                                value: $host.fanState.customPercent,
                                in: 0...100,
                                step: 5,
                                onEditingChanged: { editing in
                                    if !editing {
                                        host.setFanProfile(.custom, customPercent: host.fanState.customPercent)
                                    }
                                }
                            )
                            .disabled(host.state.busy)
                            Text("\(Int(host.fanState.customPercent))%")
                                .font(Design.Typography.xsMono)
                                .monospacedDigit()
                                .foregroundStyle(Design.Color.foreground)
                                .frame(width: 36, alignment: .trailing)
                        }
                    } else {
                        HStack {
                            Text("Automatic SMC fan management active")
                                .font(Design.Typography.xs)
                                .foregroundStyle(Design.Color.tertiaryText)
                            Spacer()
                        }
                    }
                }
                .frame(height: 24)
            }
        }
    }

    private var powerBatteryCard: some View {
        CardContainer(title: "Power & Battery Management") {
            VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                HStack {
                    Toggle("Always-On (Clamshell)", isOn: Binding(
                        get: { host.state.alwaysOn },
                        set: { host.setAlwaysOn($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(host.state.busy)
                    Spacer()
                }

                HStack {
                    Toggle("Pause Indexing Daemons", isOn: Binding(
                        get: { host.state.daemonsSuspended },
                        set: { host.setDaemonsSuspended($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(host.state.busy)
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: Design.Spacing.space1) {
                    HStack {
                        Toggle("Charge Limit", isOn: Binding(
                            get: { host.batteryState.limitEnabled },
                            set: { host.setBatteryLimit(host.batteryState.limit, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(host.state.busy)

                        Spacer()

                        if host.batteryState.limitEnabled {
                            Text("\(host.batteryState.limit)%")
                                .font(Design.Typography.xsMono)
                                .monospacedDigit()
                                .foregroundStyle(Design.Color.secondaryText)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }

                    VStack {
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
                    .frame(height: 20)
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
                Text("v1.0")
                    .font(Design.Typography.xsMono)
                    .foregroundStyle(Design.Color.tertiaryText)
            }
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack(spacing: Design.Spacing.space1) {
            Text(label)
                .font(Design.Typography.xs)
                .foregroundStyle(Design.Color.secondaryText)
            Spacer(minLength: Design.Spacing.space1)
            Text(value)
                .font(Design.Typography.xsMono)
                .monospacedDigit()
                .foregroundStyle(Design.Color.foreground)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private var socTempDisplay: String {
        if let t = host.fanState.socTemp, t > 0 { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var cpuTempDisplay: String {
        if let t = host.fanState.cpuTemp, t > 0 { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var gpuTempDisplay: String {
        if let t = host.fanState.gpuTemp, t > 0 { return String(format: "%.0f°C", t) }
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
        return host.fanState.fans.map { "\(Int($0.actualRPM))" }.joined(separator: "/") + " RPM"
    }

    private var batteryDisplay: String {
        let pct = host.batteryState.chargePercent
        let status = host.batteryState.isCharging ? "⚡" : ""
        return "\(pct)%\(status)"
    }

    private var batteryCyclesDisplay: String {
        let cycles = host.batteryState.cycleCount
        return cycles > 0 ? "\(cycles)" : "—"
    }
}

class KjolHostingController<Content: View>: NSHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(macOS 13.0, *) {
            sizingOptions = []
        }
    }
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
        p.animates = false
        let controller = KjolHostingController(rootView: KjolView().environmentObject(host))
        controller.preferredContentSize = CGSize(width: 360, height: 490)
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
