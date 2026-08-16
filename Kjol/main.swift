// Kjol — native SwiftUI menu-bar utility for power management on Apple Silicon Macs.
//
// Stable popover UI built from a fixed structure with consistent spacing
// and neutral presentation. Existing models/Host are preserved; only the
// popover view layer is replaced.

import SwiftUI
import AppKit
import Foundation
import Combine
import ServiceManagement
import Security
import CoreFoundation

// MARK: - Models

enum PowerMode: String, CaseIterable, Identifiable {
    case normal = "normal"
    case serving = "serving"
    case max = "max"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .serving: return "Serving"
        case .max: return "Max"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "leaf"
        case .serving: return "cup.and.heat.waves"
        case .max: return "flame"
        }
    }
}

struct HostState: Equatable {
    var mode: PowerMode = .normal
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

// MARK: - Fan Models

enum FanProfile: String, CaseIterable, Identifiable {
    case auto, quiet, cool, blast, custom, targetTemp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .quiet: return "Quiet"
        case .cool: return "Cool"
        case .blast: return "Blast"
        case .custom: return "Custom"
        case .targetTemp: return "Target Temp"
        }
    }
    var icon: String {
        switch self {
        case .auto: return "gearshape"
        case .quiet: return "moon"
        case .cool: return "wind"
        case .blast: return "hurricane"
        case .custom: return "slider.horizontal.3"
        case .targetTemp: return "thermometer"
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
    var profile: FanProfile = .auto
    var customPercent: Double = 50
    var targetTempC: Double = 90
    var history: [[Double]] = []
    var tempHistory: [Double] = []
}

// MARK: - Per-core CPU

struct CpuState: Equatable {
    var perCore: [Double] = []
    var pCoreCount: Int = 0
    var hasSample = false
}

final class CpuSampler {
    private var prevTotal: [Int] = []
    private var prevBusy: [Int] = []

    func sample() -> CpuState {
        var state = CpuState()
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return state }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.stride)) }

        let loads = UnsafeBufferPointer<processor_cpu_load_info>(
            start: UnsafeRawPointer(info).assumingMemoryBound(to: processor_cpu_load_info.self),
            count: Int(numCPUs))

        var total: [Int] = [], busy: [Int] = []
        for i in 0..<Int(numCPUs) {
            let t = loads[i].cpu_ticks
            let u = Int(t.0), s = Int(t.1), idle = Int(t.2), n = Int(t.3)
            total.append(u + s + idle + n)
            busy.append(u + s + n)
        }
        if prevTotal.count == total.count {
            for i in 0..<total.count {
                let dTot = max(1, total[i] - prevTotal[i])
                let dBsy = max(0, busy[i] - prevBusy[i])
                state.perCore.append(Double(dBsy) / Double(dTot))
            }
            state.hasSample = true
        }
        prevTotal = total
        prevBusy = busy

        var pCount: Int = 0
        var sz = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &pCount, &sz, nil, 0)
        state.pCoreCount = pCount
        return state
    }
}

// MARK: - XPC Client

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

    func setPowerMode(_ mode: String, completion: @escaping (Bool, String) -> Void) {
        guard let proxy = remoteProxy() else {
            completion(false, "Helper not connected")
            return
        }
        proxy.setPowerMode(mode) { success, message in
            DispatchQueue.main.async { completion(success, message) }
        }
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

    private func remoteProxy() -> KjolHelperProtocol? {
        if connection == nil {
            connect()
        }
        return connection?.remoteObjectProxy as? KjolHelperProtocol
    }
}

// MARK: - Host (ObservableObject)

final class Host: ObservableObject {
    @Published var state = HostState()
    @Published var fanState = FanState()
    @Published var cpuState = CpuState()
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
        timer?.tolerance = interval * 0.2
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Actions

    func setMode(_ mode: PowerMode) {
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        helper.setPowerMode(mode.rawValue) { [weak self] success, message in
            guard let self = self else { return }
            self.state.busy = false
            if !success {
                self.state.errorMessage = message
            }
            self.refresh()
        }
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

    func setFanProfile(_ profile: FanProfile, customPercent: Double? = nil, targetTempC: Double? = nil) {
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        let pct = customPercent ?? fanState.customPercent
        let tempC = targetTempC ?? 0
        helper.setFanProfile(profile.rawValue, rpmPercent: pct, targetTempC: tempC) { [weak self] success, message in
            guard let self = self else { return }
            self.state.busy = false
            if !success {
                self.state.errorMessage = message
            }
            self.refreshFans()
        }
    }

    func installHelper() {
        state.busy = true
        state.errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["list", "com.lappier.kjol.helper"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if output.contains("com.lappier.kjol.helper") {
                    DispatchQueue.main.async {
                        self.state.busy = false
                        self.helperInstalled = true
                        self.refresh()
                    }
                    return
                }
            } catch {
                // Continue to installation
            }

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

            let installCmd = [
                "launchctl bootout system/com.lappier.kjol.helper 2>/dev/null || true",
                "mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons /var/log",
                "cp '\(srcBin)' '\(dstBin)'",
                "chown root:wheel '\(dstBin)'",
                "chmod 755 '\(dstBin)'",
                "cp '\(tmpPlist)' '\(dstPlist)'",
                "chown root:wheel '\(dstPlist)'",
                "chmod 644 '\(dstPlist)'",
                "launchctl bootstrap system '\(dstPlist)'"
            ].joined(separator: " && ")

            let script = "do shell script \"\(installCmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", script]
            let errPipe = Pipe()
            osa.standardError = errPipe
            var installOK = false
            var installErr = ""
            do {
                try osa.run()
                osa.waitUntilExit()
                installOK = (osa.terminationStatus == 0)
                if !installOK {
                    let d = errPipe.fileHandleForReading.readDataToEndOfFile()
                    installErr = String(data: d, encoding: .utf8) ?? "unknown error"
                }
            } catch {
                installErr = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.state.busy = false
                if installOK {
                    self.helperInstalled = true
                    self.refresh()
                } else {
                    self.state.errorMessage = "Helper installation failed: \(installErr)"
                }
            }
        }
    }

    // MARK: - Refresh

    func refresh() {
        helper.getStatus { [weak self] status in
            guard let self = self else { return }

            let modeStr = status["mode"] as? String ?? "normal"
            let mode = PowerMode(rawValue: modeStr) ?? .normal

            let new = HostState(
                mode: mode,
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

    func checkHelperInstalled() {
        let plist = "/Library/LaunchDaemons/com.lappier.kjol.helper.plist"
        let bin = "/Library/PrivilegedHelperTools/com.lappier.kjol.helper"
        helperInstalled = FileManager.default.fileExists(atPath: plist)
            && FileManager.default.fileExists(atPath: bin)
    }
}

// MARK: - New UI

private func kjolQuit() {
    NSApplication.shared.terminate(nil)
}

struct KjolView: View {
    @EnvironmentObject var host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView
            MetricsPanel(
                tempText: tempDisplay,
                fansText: fansDisplay,
                cpuText: cpuDisplay
            )
            controlsView
            footerView
        }
        .padding(16)
        .frame(width: 360)
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: host.state.mode.icon)
            Text("Kjol")
                .font(.system(size: 15, weight: .semibold))
            Text(host.state.mode.title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if host.state.busy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var controlsView: some View {
        VStack(spacing: 12) {
            if !host.helperInstalled {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text("Kjol needs a privileged helper to manage power settings. You'll be asked for an admin password once.")
                        .font(.system(.body))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Install Helper") {
                        host.installHelper()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                controlGroup(label: "Power mode") {
                    Picker("", selection: Binding(
                        get: { host.state.mode },
                        set: { host.setMode($0) }
                    )) {
                        ForEach(PowerMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(host.state.busy)
                }

                controlGroup(label: "Fans") {
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
                }

                if host.fanState.profile == .custom {
                    fanSlider(
                        title: "Speed",
                        value: $host.fanState.customPercent,
                        unit: "%",
                        range: 0...100,
                        step: 5,
                        onChange: { host.setFanProfile(.custom, customPercent: $0) }
                    )
                }

                if host.fanState.profile == .targetTemp {
                    fanSlider(
                        title: "Target",
                        value: $host.fanState.targetTempC,
                        unit: "°C",
                        range: 50...100,
                        step: 1,
                        onChange: { host.setFanProfile(.targetTemp, targetTempC: $0) }
                    )
                }

                controlGroup(label: "Always-On") {
                    Toggle("", isOn: Binding(
                        get: { host.state.alwaysOn },
                        set: { host.setAlwaysOn($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(host.state.busy)
                }

                controlGroup(label: "Background") {
                    Toggle("Pause background daemons", isOn: Binding(
                        get: { host.state.daemonsSuspended },
                        set: { host.setDaemonsSuspended($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(host.state.busy)
                }
            }
        }
    }

    private var footerView: some View {
        VStack(spacing: 8) {
            if let err = host.state.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.system(.caption2, design: .default))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Quit", action: kjolQuit)
                Spacer(minLength: 0)
                if !host.helperInstalled {
                    Text("Helper not installed")
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func controlGroup(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .default))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func fanSlider(title: String, value: Binding<Double>, unit: String, range: ClosedRange<Double>, step: Double, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(.caption2, design: .default))
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .leading)
                Slider(value: value, in: range, step: step) { editing in
                    if !editing {
                        onChange(value.wrappedValue)
                    }
                }
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(.horizontal, 2)
    }

    private var tempDisplay: String {
        if let t = host.fanState.socTemp {
            return String(format: "%.0f°C", t)
        }
        return "—"
    }

    private var fansDisplay: String {
        if host.fanState.fans.isEmpty {
            return "—"
        }
        return host.fanState.fans.map { "\(Int($0.actualRPM)) rpm" }.joined(separator: "  ")
    }

    private var cpuDisplay: String {
        if !host.cpuState.hasSample {
            return "Sampling…"
        }
        let columns = max(1, min(5, host.cpuState.perCore.count))
        let samples = host.cpuState.perCore.prefix(columns)
        return samples.map { "\(Int($0 * 100))%" }.joined(separator: " ")
    }
}

struct MetricsPanel: View {
    let tempText: String
    let fansText: String
    let cpuText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SoC temp")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(tempText)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Fans")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(fansText)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("CPU")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(cpuText)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - App Entry

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private let host = Host()
    private var popoverShown = false {
        didSet { updatePolling() }
    }
    private var cancellables = Set<AnyCancellable>()

    private func updateStatusItemIcon() {
        let mode = host.state.mode
        let fanManual = host.fanState.profile != .auto
        let imageName: String
        if let err = host.state.errorMessage, !err.isEmpty {
            imageName = "exclamationmark.octagon.fill"
        } else if host.state.busy {
            imageName = "bolt.horizontal.icloud.fill"
        } else if fanManual {
            imageName = "fan.fill"
        } else {
            imageName = mode == .max ? "bolt.fill" : (mode == .serving ? "bolt.circle" : "bolt")
        }
        statusItem.button?.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Kjol")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.contentTintColor = host.state.alwaysOn ? .controlAccentColor : nil
        var tip = "Kjol — \(mode.title)"
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
        p.contentViewController = NSHostingController(rootView: KjolView().environmentObject(host))
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
                positionPopover(window, relativeTo: btn)
            }
        }
        popoverShown = true
    }

    private func positionPopover(_ window: NSWindow, relativeTo button: NSStatusBarButton) {
        guard let screen = button.window?.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let popoverFrame = window.frame
        let buttonScreenRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? button.bounds

        var x = min(buttonScreenRect.midX - popoverFrame.width / 2, screenFrame.maxX - popoverFrame.width - 8)
        x = max(x, screenFrame.minX + 8)
        let y = buttonScreenRect.minY - 4

        window.setFrameTopLeftPoint(NSPoint(x: x, y: y))
    }

    func popoverDidClose(_ notification: Notification) {
        popoverShown = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // polling stops automatically when popover closes
    }
}

// Classic entry point.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
