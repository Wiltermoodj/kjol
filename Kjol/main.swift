import SwiftUI
import AppKit
import Foundation
import Combine
import ServiceManagement

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

struct HeaderView: View {
    @ObservedObject var host: Host

    var body: some View {
        HStack(spacing: Design.Spacing.space2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: Design.Icon.action))
                .foregroundStyle(Design.Color.accent)
            Text("Kjol")
                .font(Design.Typography.base)
            Spacer(minLength: 0)
            if host.busy {
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
}

struct TelemetryCardView: View {
    @ObservedObject var telemetryVM: TelemetryViewModel

    var body: some View {
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
                        metricRow(label: "P-Cores (\(telemetryVM.pCoreCount))", value: pCoreDisplay)
                        metricRow(label: "E-Cores (\(telemetryVM.eCoreCount))", value: eCoreDisplay)
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
        if let t = telemetryVM.socTemp, t > 0 { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var cpuTempDisplay: String {
        if let t = telemetryVM.cpuTemp, t > 0 { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var gpuTempDisplay: String {
        if let t = telemetryVM.gpuTemp, t > 0 { return String(format: "%.0f°C", t) }
        return "—"
    }

    private var pCoreDisplay: String {
        guard telemetryVM.hasCpuSample else { return "—" }
        return String(format: "%.0f%%", telemetryVM.pCoreUsage * 100)
    }

    private var eCoreDisplay: String {
        guard telemetryVM.hasCpuSample else { return "—" }
        return String(format: "%.0f%%", telemetryVM.eCoreUsage * 100)
    }

    private var fansDisplay: String {
        if telemetryVM.fans.isEmpty { return "—" }
        return telemetryVM.fans.map { "\(Int($0.actualRPM))" }.joined(separator: "/") + " RPM"
    }

    private var batteryDisplay: String {
        let pct = telemetryVM.batteryCharge
        let status = telemetryVM.isCharging ? "⚡" : ""
        return "\(pct)%\(status)"
    }

    private var batteryCyclesDisplay: String {
        let cycles = telemetryVM.batteryCycles
        return cycles > 0 ? "\(cycles)" : "—"
    }
}

struct HelperMissingCardView: View {
    @ObservedObject var host: Host

    var body: some View {
        CardContainer(title: "Privileged Helper") {
            VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                Text(host.needsReinstall
                      ? "The helper daemon is out of date. Run the Kjol installer package (.pkg) to update it."
                      : "Kjol requires its background helper daemon to manage SMC hardware keys and system power policies. Please run the Kjol installer package (.pkg).")
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Connection") {
                    host.checkHelperInstalled()
                    host.refresh()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(host.busy)
            }
        }
    }
}

struct FanControlCardView: View {
    @ObservedObject var fanVM: FanControlViewModel
    @ObservedObject var host: Host

    private var isCustom: Bool {
        fanVM.profile == .custom
    }

    var body: some View {
        CardContainer(title: "Fan Control Strategy") {
            VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                Picker("", selection: Binding(
                    get: { fanVM.profile },
                    set: { fanVM.selectProfile($0) }
                )) {
                    ForEach(FanProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(host.busy)

                HStack(spacing: Design.Spacing.space2) {
                    Text("Speed")
                        .font(Design.Typography.xs)
                        .foregroundStyle(isCustom ? Design.Color.secondaryText : Design.Color.tertiaryText)
                    Slider(
                        value: Binding(
                            get: { fanVM.customPercent },
                            set: { fanVM.customPercent = $0 }
                        ),
                        in: 0...100,
                        step: 5,
                        onEditingChanged: { editing in
                            if !editing {
                                fanVM.setCustomPercent(fanVM.customPercent)
                            }
                        }
                    )
                    .disabled(!isCustom || host.busy)
                    .opacity(isCustom ? 1.0 : 0.4)

                    Text("\(Int(fanVM.customPercent))%")
                        .font(Design.Typography.xsMono)
                        .monospacedDigit()
                        .foregroundStyle(isCustom ? Design.Color.foreground : Design.Color.tertiaryText)
                        .frame(width: 36, alignment: .trailing)
                }
                .frame(height: 24)
            }
        }
    }
}

struct PowerBatteryCardView: View {
    @ObservedObject var powerVM: PowerViewModel
    @ObservedObject var host: Host

    var body: some View {
        CardContainer(title: "Power & Battery Management") {
            VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                HStack {
                    Toggle("Always-On (Clamshell)", isOn: Binding(
                        get: { powerVM.alwaysOn },
                        set: { powerVM.toggleAlwaysOn($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(host.busy)
                    Spacer()
                }

                HStack {
                    Toggle("Pause Indexing Daemons", isOn: Binding(
                        get: { powerVM.daemonsSuspended },
                        set: { powerVM.toggleDaemons($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(host.busy)
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: Design.Spacing.space1) {
                    HStack {
                        Toggle("Charge Limit", isOn: Binding(
                            get: { powerVM.limitEnabled },
                            set: { powerVM.setChargeLimit(powerVM.chargeLimit, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(host.busy)

                        Spacer()

                        Text("\(powerVM.chargeLimit)%")
                            .font(Design.Typography.xsMono)
                            .monospacedDigit()
                            .foregroundStyle(powerVM.limitEnabled ? Design.Color.secondaryText : Design.Color.tertiaryText)
                            .frame(width: 36, alignment: .trailing)
                    }

                    HStack(spacing: Design.Spacing.space2) {
                        Slider(
                            value: Binding(
                                get: { Double(powerVM.chargeLimit) },
                                set: { powerVM.setChargeLimit(Int($0), enabled: true) }
                            ),
                            in: 50...90,
                            step: 5
                        )
                        .disabled(!powerVM.limitEnabled || host.busy)
                        .opacity(powerVM.limitEnabled ? 1.0 : 0.4)
                    }
                    .frame(height: 20)
                }
            }
        }
    }
}

struct FooterView: View {
    @ObservedObject var host: Host

    var body: some View {
        VStack(spacing: Design.Spacing.space1) {
            if let err = host.errorMessage, !err.isEmpty {
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
        .frame(minHeight: 20)
    }
}

struct KjolView: View {
    @EnvironmentObject var host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space3) {
            HeaderView(host: host)
            TelemetryCardView(telemetryVM: host.telemetryVM)
            if !host.helperInstalled {
                HelperMissingCardView(host: host)
            } else {
                FanControlCardView(fanVM: host.fanControlVM, host: host)
                PowerBatteryCardView(powerVM: host.powerVM, host: host)
            }
            Spacer(minLength: 0)
            FooterView(host: host)
        }
        .padding(Design.Spacing.space4)
        .frame(width: 360, height: 490)
        .background(Design.Color.background)
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
        // Keep status item icon strictly uniform in size and template behavior to eliminate menu bar layout shifts.
        statusItem.button?.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: "Kjol")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.contentTintColor = host.powerVM.alwaysOn ? .controlAccentColor : nil
        var tip = "Kjol"
        if let t = host.telemetryVM.socTemp { tip += String(format: " · %.0f°C", t) }
        if !host.telemetryVM.fans.isEmpty {
            let rpms = host.telemetryVM.fans.map { "\(Int($0.actualRPM))" }.joined(separator: "/")
            tip += " · \(rpms) rpm"
        }
        if host.powerVM.alwaysOn { tip += " · Always-On" }
        if let err = host.errorMessage, !err.isEmpty { tip += " · \(err)" }
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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: "Kjol")
            btn.image?.isTemplate = true
            btn.action = #selector(togglePopover(_:))
            btn.target = self
        }

        updateStatusItemIcon()
        let scheduleIconUpdate: (Any) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItemIcon()
            }
        }
        host.telemetryVM.objectWillChange
            .sink(receiveValue: scheduleIconUpdate)
            .store(in: &cancellables)
        host.powerVM.objectWillChange
            .sink(receiveValue: scheduleIconUpdate)
            .store(in: &cancellables)
        host.fanControlVM.objectWillChange
            .sink(receiveValue: scheduleIconUpdate)
            .store(in: &cancellables)
        host.$busy
            .sink(receiveValue: scheduleIconUpdate)
            .store(in: &cancellables)
        host.$errorMessage
            .sink(receiveValue: scheduleIconUpdate)
            .store(in: &cancellables)

        updatePolling()
    }

    private func buildPopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.animates = false
        p.contentSize = CGSize(width: 360, height: 490)
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
            pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
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
        if host.powerVM.alwaysOn {
            host.syncSetAlwaysOn(false)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
