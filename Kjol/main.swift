
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


struct CpuState: Equatable {
    var perCore: [Double] = []
    var pCoreCount: Int = 0
    var hasSample = false
}

final class CpuSampler {
    private var prevTotal: [UInt32] = []
    private var prevBusy: [UInt32] = []
    private let cachedPCoreCount: Int

    init() {
        var pCount: Int = 0
        var sz = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &pCount, &sz, nil, 0)
        cachedPCoreCount = pCount
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
        }
        prevTotal = total
        prevBusy = busy

        state.pCoreCount = cachedPCoreCount
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
                do {
                    if service.status != .enabled {
                        try service.register()
                    }
                    DispatchQueue.main.async {
                        self.state.busy = false
                        self.helperInstalled = true
                        self.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.state.busy = false
                        self.state.errorMessage = "Helper installation failed: \(error.localizedDescription)"
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.state.busy = false
                    self.state.errorMessage = "macOS 13.0+ required for SMAppService installation."
                }
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
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: "com.lappier.kjol.helper.plist")
            helperInstalled = (service.status == .enabled)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space4) {
            headerView
            MetricsPanel(
                tempText: tempDisplay,
                fansText: fansDisplay,
                cpuText: cpuDisplay
            )
            controlsView
            footerView
        }
        .padding(Design.Spacing.space4)
        .frame(width: 380)
        .background(Design.Color.background)
    }

    private var headerView: some View {
        HStack(spacing: Design.Spacing.space2) {
            Image(systemName: "bolt")
            Text("Kjol")
                .font(Design.Typography.base)
                .fontWeight(.semibold)
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .opacity(host.state.busy ? 1 : 0)
        }
    }

    private var controlsView: some View {
        VStack(spacing: Design.Spacing.space3) {
            if !host.helperInstalled {
                VStack(spacing: Design.Spacing.space4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Design.Icon.nav))
                        .foregroundStyle(Design.Color.warning)
                    Text("Kjol needs a privileged helper to manage power settings. You'll be asked for an admin password once.")
                        .font(Design.Typography.base)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Design.Color.secondaryText)
                    Button("Install Helper") {
                        host.installHelper()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
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
                    Toggle("Pause Background Daemons", isOn: Binding(
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
        VStack(spacing: Design.Spacing.space2) {
            if let err = host.state.errorMessage, !err.isEmpty {
                Text(err)
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Quit", action: kjolQuit)
                Spacer(minLength: 0)
                if !host.helperInstalled {
                    Text("Helper Not Installed")
                        .font(Design.Typography.xs)
                        .foregroundStyle(Design.Color.secondaryText)
                }
            }
        }
    }

    private func controlGroup(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space2) {
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
                    .frame(width: 56, alignment: .leading)
                Slider(value: value, in: range, step: step) { editing in
                    if !editing {
                        onChange(value.wrappedValue)
                    }
                }
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(Design.Typography.xsMonospaced)
                    .foregroundStyle(Design.Color.tertiaryText)
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
            return "—"
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
        VStack(alignment: .leading, spacing: Design.Spacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.space2) {
                Text("SoC Temp")
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                Spacer(minLength: 0)
                Text(tempText)
                    .font(Design.Typography.xsMonospaced)
                    .foregroundStyle(Design.Color.foreground)
            }
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.space2) {
                Text("Fans")
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                Spacer(minLength: 0)
                Text(fansText)
                    .font(Design.Typography.xsMonospaced)
                    .foregroundStyle(Design.Color.foreground)
            }
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.space2) {
                Text("CPU")
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                Spacer(minLength: 0)
                Text(cpuText)
                    .font(Design.Typography.xsMonospaced)
                    .foregroundStyle(Design.Color.foreground)
            }
        }
        .padding(Design.Spacing.space3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
