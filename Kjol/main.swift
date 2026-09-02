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
    case auto, quiet, adaptive, blast, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .quiet: return "Quiet"
        case .adaptive: return "Adaptive"
        case .blast: return "Blast"
        case .custom: return "Custom"
        }
    }
    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .quiet: return "leaf.fill"
        case .adaptive: return "waveform.path.ecg"
        case .blast: return "flame.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
    var badgeText: String {
        switch self {
        case .auto: return "Native"
        case .quiet: return "25%"
        case .adaptive: return "Predictive"
        case .blast: return "100%"
        case .custom: return "Manual"
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

func loadBundleNSImage(_ name: String) -> NSImage? {
    if let path = Bundle.main.path(forResource: name, ofType: nil) ??
                  Bundle.main.path(forResource: (name as NSString).deletingPathExtension, ofType: (name as NSString).pathExtension) {
        return NSImage(contentsOfFile: path)
    }
    return NSImage(named: name)
}

func bundleImage(_ name: String) -> Image? {
    if let nsImg = loadBundleNSImage(name) {
        return Image(nsImage: nsImg)
    }
    return nil
}

struct CardContainer<Content: View>: View {
    let title: String
    let backgroundResource: String?
    let content: Content

    init(title: String, backgroundResource: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.backgroundResource = backgroundResource
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
        .background {
            ZStack {
                Design.Color.cardBackground
                if let res = backgroundResource, let img = bundleImage(res) {
                    GeometryReader { geo in
                        img
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .opacity(0.18)
                            .blendMode(.luminosity)
                            .overlay(
                                LinearGradient(
                                    colors: [
                                        Design.Color.cardBackground.opacity(0.6),
                                        Design.Color.cardBackground.opacity(0.92)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SwiftUI.Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct HeaderView: View {
    @ObservedObject var host: Host

    var body: some View {
        HStack(spacing: Design.Spacing.space2) {
            if let motif = bundleImage("clamshell-motif.jpg") {
                motif
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: Design.Icon.action))
                    .foregroundStyle(Design.Color.accent)
            }
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
        guard pct > 0 else { return "—" }
        let tempStr = telemetryVM.batteryTemp != nil ? " • \(Int(telemetryVM.batteryTemp!))°C" : ""
        if telemetryVM.forcedDischarge {
            return "\(pct)% (Discharging)\(tempStr)"
        } else if telemetryVM.heatProtectionActive {
            return "\(pct)% (Overheated)\(tempStr)"
        } else if telemetryVM.topUpActive {
            return "\(pct)% (Top Up ⚡)\(tempStr)"
        } else if telemetryVM.chargingInhibited {
            return "\(pct)% (Hold)\(tempStr)"
        } else if telemetryVM.isCharging {
            return "\(pct)% ⚡\(tempStr)"
        } else {
            return "\(pct)%\(tempStr)"
        }
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
    @ObservedObject var telemetryVM: TelemetryViewModel
    @ObservedObject var host: Host

    private var isCustom: Bool {
        fanVM.profile == .custom
    }

    var body: some View {
        CardContainer(title: "Fan Control Strategy", backgroundResource: "fan-header.jpg") {
            VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                // Preset Option Grid (Row 1: Auto, Quiet, Adaptive | Row 2: Blast, Custom)
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        fanProfileButton(.auto)
                        fanProfileButton(.quiet)
                        fanProfileButton(.adaptive)
                    }
                    HStack(spacing: 6) {
                        fanProfileButton(.blast)
                        fanProfileButton(.custom)
                    }
                }

                // Custom Slider Section (collapsible / animated)
                if isCustom {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Design.Spacing.space2) {
                            Text("Target Speed")
                                .font(Design.Typography.xs)
                                .foregroundStyle(Design.Color.secondaryText)
                            Spacer()
                            Text("\(Int(fanVM.customPercent))%")
                                .font(Design.Typography.xsMono)
                                .monospacedDigit()
                                .bold()
                                .foregroundStyle(Design.Color.foreground)
                        }

                        Slider(
                            value: Binding(
                                get: { fanVM.customPercent },
                                set: { fanVM.setCustomPercent($0) }
                            ),
                            in: 0...100,
                            step: 5,
                            onEditingChanged: { editing in
                                if !editing {
                                    fanVM.setCustomPercent(fanVM.customPercent, immediate: true)
                                }
                            }
                        )
                        .disabled(host.busy)

                        // Quick Snap Chips
                        HStack(spacing: 4) {
                            quickSnapButton(percent: 25)
                            quickSnapButton(percent: 50)
                            quickSnapButton(percent: 75)
                            quickSnapButton(percent: 100)
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Live Per-Fan RPM Status Badges
                if !telemetryVM.fans.isEmpty {
                    Divider()
                        .padding(.vertical, 2)

                    HStack(spacing: Design.Spacing.space2) {
                        ForEach(telemetryVM.fans) { fan in
                            HStack(spacing: 4) {
                                Image(systemName: "fanblades.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(fan.mode == 1 ? Design.Color.accent : Design.Color.secondaryText)
                                Text("Fan \(fan.index + 1):")
                                    .font(Design.Typography.xs)
                                    .foregroundStyle(Design.Color.secondaryText)
                                Text("\(Int(fan.actualRPM))")
                                    .font(Design.Typography.xsMono)
                                    .bold()
                                    .foregroundStyle(Design.Color.foreground)
                                Text("RPM")
                                    .font(Design.Typography.xs)
                                    .foregroundStyle(Design.Color.tertiaryText)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Design.Color.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func fanProfileButton(_ profile: FanProfile) -> some View {
        let selected = fanVM.profile == profile
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                fanVM.selectProfile(profile)
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: profile.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(profile.title)
                    .font(Design.Typography.xs)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                selected ? Design.Color.accent.opacity(0.2) : Design.Color.background,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selected ? Design.Color.accent : Design.Color.tertiaryText.opacity(0.25), lineWidth: 1)
            )
            .foregroundStyle(selected ? Design.Color.accent : Design.Color.foreground)
        }
        .buttonStyle(.plain)
        .disabled(host.busy)
    }

    private func quickSnapButton(percent: Double) -> some View {
        let isCurrent = Int(fanVM.customPercent) == Int(percent)
        return Button(action: {
            fanVM.setCustomPercent(percent, immediate: true)
        }) {
            Text("\(Int(percent))%")
                .font(Design.Typography.xsMono)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(isCurrent ? Design.Color.accent.opacity(0.25) : Design.Color.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(isCurrent ? Design.Color.accent : Design.Color.tertiaryText.opacity(0.2), lineWidth: 1)
                )
                .foregroundStyle(isCurrent ? Design.Color.accent : Design.Color.secondaryText)
        }
        .buttonStyle(.plain)
        .disabled(host.busy)
    }
}

struct PowerBatteryCardView: View {
    @ObservedObject var powerVM: PowerViewModel
    @ObservedObject var host: Host
    @State private var showAdvanced: Bool = false

    var body: some View {
        CardContainer(title: "Power & Battery Management", backgroundResource: "battery-header.jpg") {
            VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                // 1. Always-On & Daemons
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

                if powerVM.daemonsFailsafeTriggered && !powerVM.daemonsSuspended {
                    Button(action: {
                        powerVM.toggleDaemons(true)
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(Design.Typography.xs)
                                .foregroundStyle(Design.Color.warning)
                            Text("Auto-paused (4h safety limit). Click to re-engage.")
                                .font(Design.Typography.xs)
                                .foregroundStyle(Design.Color.warning)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }

                Divider()

                // 2. Main Charge Limit Control
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

                    if powerVM.limitEnabled {
                        Text("Sailing Range: \(max(1, powerVM.chargeLimit - powerVM.sailingDiff))% – \(powerVM.chargeLimit)%")
                            .font(Design.Typography.xsMono)
                            .foregroundStyle(Design.Color.tertiaryText)
                    }
                }

                // 3. Quick Action Buttons: Top Up (100%) & Discharge on AC
                HStack(spacing: Design.Spacing.space2) {
                    Button(action: {
                        powerVM.toggleTopUp(!powerVM.topUpActive)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: powerVM.topUpActive ? "bolt.fill" : "bolt")
                            Text("Top Up (100%)")
                                .font(Design.Typography.xs)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(powerVM.topUpActive ? Design.Color.accent.opacity(0.2) : Design.Color.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(powerVM.topUpActive ? Design.Color.accent : Design.Color.tertiaryText.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(host.busy)

                    Button(action: {
                        powerVM.toggleDischarge(!powerVM.dischargeActive)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: powerVM.dischargeActive ? "arrow.down.circle.fill" : "arrow.down.circle")
                            Text("Discharge to Limit")
                                .font(Design.Typography.xs)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(powerVM.dischargeActive ? Design.Color.warning.opacity(0.2) : Design.Color.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(powerVM.dischargeActive ? Design.Color.warning : Design.Color.tertiaryText.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(host.busy)
                }

                Divider()

                // 4. Advanced Battery Settings Expander
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAdvanced.toggle()
                    }
                }) {
                    HStack {
                        Text("Advanced Battery Controls")
                            .font(Design.Typography.xs)
                            .foregroundStyle(Design.Color.secondaryText)
                        Spacer()
                        Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                            .font(Design.Typography.xs)
                            .foregroundStyle(Design.Color.tertiaryText)
                    }
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    VStack(alignment: .leading, spacing: Design.Spacing.space2) {
                        // Sailing Gap Slider
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Sailing Gap (Hysteresis)")
                                    .font(Design.Typography.xs)
                                    .foregroundStyle(Design.Color.secondaryText)
                                Spacer()
                                Text("±\(powerVM.sailingDiff)%")
                                    .font(Design.Typography.xsMono)
                                    .foregroundStyle(Design.Color.tertiaryText)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(powerVM.sailingDiff) },
                                    set: { powerVM.setSailingDiff(Int($0)) }
                                ),
                                in: 2...10,
                                step: 1
                            )
                            .controlSize(.small)
                            .disabled(host.busy)
                        }

                        // Overheat Protection
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Toggle("Heat Protection", isOn: Binding(
                                    get: { powerVM.heatProtectionEnabled },
                                    set: { powerVM.setHeatProtection(enabled: $0, maxTemp: powerVM.maxTempC) }
                                ))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(host.busy)

                                Spacer()

                                Text("\(Int(powerVM.maxTempC))°C")
                                    .font(Design.Typography.xsMono)
                                    .foregroundStyle(powerVM.heatProtectionEnabled ? Design.Color.secondaryText : Design.Color.tertiaryText)
                            }

                            if powerVM.heatProtectionEnabled {
                                Slider(
                                    value: Binding(
                                        get: { powerVM.maxTempC },
                                        set: { powerVM.setHeatProtection(enabled: true, maxTemp: $0) }
                                    ),
                                    in: 30...45,
                                    step: 1
                                )
                                .controlSize(.small)
                                .disabled(host.busy)
                            }
                        }

                        // Battery Calibration Mode
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Battery Calibration")
                                    .font(Design.Typography.xs)
                                    .foregroundStyle(Design.Color.secondaryText)
                                Spacer()
                                if powerVM.calibrationState != "idle" && powerVM.calibrationState != "completed" {
                                    Button("Cancel") {
                                        powerVM.triggerCalibration(action: "stop")
                                    }
                                    .buttonStyle(.plain)
                                    .font(Design.Typography.xs)
                                    .foregroundStyle(Design.Color.warning)
                                } else {
                                    Button("Start Cycle") {
                                        powerVM.triggerCalibration(action: "start")
                                    }
                                    .buttonStyle(.plain)
                                    .font(Design.Typography.xs)
                                    .foregroundStyle(Design.Color.accent)
                                }
                            }

                            if powerVM.calibrationState != "idle" {
                                VStack(alignment: .leading, spacing: 2) {
                                    ProgressView(value: powerVM.calibrationProgress, total: 1.0)
                                        .controlSize(.small)
                                    Text(powerVM.calibrationMessage)
                                        .font(Design.Typography.xsMono)
                                        .foregroundStyle(Design.Color.tertiaryText)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

struct UpdateBannerView: View {
    @ObservedObject var updateVM: UpdateViewModel

    var body: some View {
        switch updateVM.state {
        case .available(let info):
            HStack(spacing: Design.Spacing.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Available: v\(info.version)")
                        .font(Design.Typography.xs)
                        .bold()
                        .foregroundStyle(Design.Color.accent)
                    Text("Click to download & install")
                        .font(Design.Typography.xs)
                        .foregroundStyle(Design.Color.secondaryText)
                }
                Spacer()
                Button("Update Now") {
                    updateVM.startDownload(for: info)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(Design.Spacing.space2)
            .background(Design.Color.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .downloading(let progress):
            HStack(spacing: Design.Spacing.space2) {
                Text("Downloading Update...")
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                Spacer()
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(Design.Typography.xsMono)
                    .foregroundStyle(Design.Color.secondaryText)
            }
            .padding(Design.Spacing.space2)
            .background(Design.Color.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .readyToInstall(let url):
            HStack(spacing: Design.Spacing.space2) {
                Text("Update Ready")
                    .font(Design.Typography.xs)
                    .bold()
                Spacer()
                Button("Launch Installer") {
                    updateVM.installUpdate(localURL: url)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(Design.Spacing.space2)
            .background(Design.Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        default:
            EmptyView()
        }
    }
}

struct FooterView: View {
    @ObservedObject var host: Host
    @ObservedObject var updateVM: UpdateViewModel

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

                switch updateVM.state {
                case .checking:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Checking...")
                            .font(Design.Typography.xs)
                            .foregroundStyle(Design.Color.tertiaryText)
                    }
                case .upToDate:
                    Text("Up to Date (v\(currentVersion))")
                        .font(Design.Typography.xsMono)
                        .foregroundStyle(Design.Color.tertiaryText)
                case .error:
                    Button("Check Failed: Retry") {
                        updateVM.checkForUpdates(silent: false)
                    }
                    .buttonStyle(.plain)
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.warning)
                default:
                    Button("Check for Updates") {
                        updateVM.checkForUpdates(silent: false)
                    }
                    .buttonStyle(.plain)
                    .font(Design.Typography.xs)
                    .foregroundStyle(Design.Color.secondaryText)
                }
            }
        }
        .frame(minHeight: 20)
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

struct KjolView: View {
    @EnvironmentObject var host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.space3) {
            HeaderView(host: host)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Design.Spacing.space3) {
                    TelemetryCardView(telemetryVM: host.telemetryVM)
                    if !host.helperInstalled {
                        HelperMissingCardView(host: host)
                    } else {
                        FanControlCardView(fanVM: host.fanControlVM, telemetryVM: host.telemetryVM, host: host)
                        PowerBatteryCardView(powerVM: host.powerVM, host: host)
                    }
                    UpdateBannerView(updateVM: host.updateVM)
                }
                .padding(.bottom, 2)
            }
            FooterView(host: host, updateVM: host.updateVM)
        }
        .padding(Design.Spacing.space4)
        .frame(width: 360, height: 530)
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

    private func loadStatusItemImage() -> NSImage {
        if let img = loadBundleNSImage("KjolStatusIcon.png") ?? loadBundleNSImage("KjolStatusIcon") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(systemSymbolName: "bolt", accessibilityDescription: "Kjol") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    private func updateStatusItemIcon() {
        // Keep status item icon strictly uniform in size and template behavior to eliminate menu bar layout shifts.
        statusItem.button?.image = loadStatusItemImage()
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
            host.updateVM.checkForUpdates(silent: true)
            host.startPolling(interval: 5.0)
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
            btn.image = loadStatusItemImage()
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
        p.contentSize = CGSize(width: 360, height: 530)
        let controller = KjolHostingController(rootView: KjolView().environmentObject(host))
        controller.preferredContentSize = CGSize(width: 360, height: 530)
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
