# Kjol — UI/UX Optimization Recommendations

Research-backed recommendations for polishing the Kjol menu-bar app (SwiftUI, NSPanel, LSUIElement) and integrating fan control. References: Apple HIG (popovers, the-menu-bar, segmented-controls), Bjango "Designing macOS menu bar extras", TG Pro, iStat Menus, AlDente, Bartender, Arc.

Current state audited from `Kjol/main.swift`: 480×720 NSPanel, 5 stacked cards (header, mode, always-on, daemons, full blast) + footer, 3s icon timer, osascript helper install.

---

## 1. Layout Optimization — 4+ sections without overwhelm

**Problem:** current popover is 480×720 with 5 full cards each carrying headline + description + control. That's a *window*, not a menu-bar popover. Reference apps (iStat Menus, AlDente) stay at 300–380 pt wide and < 500 pt tall.

**Recommendations:**
- **Target 360 pt wide, ~420–480 pt tall.** Cut per-card descriptions; move explanations to tooltips (`.help("…")`) or a one-time onboarding popover (TG Pro pattern: first-launch explainer popover).
- **Compress hierarchy to: Header → Mode → Toggles group → Fans → Footer.**
  - Merge Always-On + Daemons into one "System" card with two compact toggle rows (label + switch, caption subtitle only when ON).
  - **Demote Kjol from a card to a single header-level button** — it's a macro, not a section. Put a prominent "Kjol" toggle-style button (bolt.fill, red tint when active) in the header row, AlDente-style. Saves ~120 pt.
- **Progressive disclosure for fans:** collapsed row by default ("Fans · Auto · 1840 RPM" + chevron); `DisclosureGroup` expands to controls. iStat Menus and BetterDisplay both use expand-on-demand to keep the resting state glanceable.
- **Remove ScrollView** — a menu-bar popover that scrolls signals over-stuffing (HIG: "limit the amount of functionality in the popover to a few related tasks"). Everything should fit unscrolled at rest; expansion animates the panel taller.
- Segmented control labels: shorten to **Normal / Serving / Max** (current full titles "Serving (low power off, keep awake)" will truncate badly in segments). Details go in `.help()` tooltips.

**Proposed resting layout (~360×430):**
```
┌──────────────────────────────────┐
│ ⚡ Kjol      [⚡ Kjol]  │  header + macro button
│ mode: serving · awake · fans auto│  caption status line
├──────────────────────────────────┤
│ POWER POSTURE                    │
│ [ 🍃 Normal | ☕ Serving | 🔥 Max ]│  segmented, icons+text
├──────────────────────────────────┤
│ SYSTEM                           │
│ Always-On (lid closed)      (⬤) │
│ Suspend Daemons             (◯) │
├──────────────────────────────────┤
│ FANS            Auto · 1840 RPM ▸│  collapsed DisclosureGroup
├──────────────────────────────────┤
│ Helper ● Connected    ⚙︎  ⏻ Quit │  footer strip
└──────────────────────────────────┘
```

## 2. Status-bar Icon Design — state matrix

Rules (Bjango): 22 pt max height, ~16×16 pt glyph weight, `isTemplate = true`, opacity for shading, never separate light/dark assets.

**Don't encode all 3×2×2 = 12 combos as distinct glyphs** — users can't decode them. Encode the *primary* dimension (mode) in the glyph, secondary states as small modifiers:

| State | Symbol | Notes |
|---|---|---|
| Normal | `bolt` (outline) | baseline |
| Serving | `bolt.fill` | filled = engaged |
| Max | `bolt.fill` + `flame` badge, or `flame.fill` | distinct silhouette |
| + Always-on | tiny dot under glyph (draw composite NSImage) | iStat pattern |
| + Fans manual/max | replace badge with `fanblades.fill` when fan override active | fans trump always-on badge (rarer, more important) |
| Error / helper down | `bolt.slash` + `withSymbolConfiguration(.init(paletteColors:[.systemRed]))`, `isTemplate=false` for the red variant | red only for failure |
| Transitioning | keep glyph, animate opacity 100→35→100% | Apple uses 35% for disabled |

Implementation: build composite via `NSImage(size:flipped:drawingHandler:)` drawing SF Symbol + 3 pt dot; keep template=true so it tints. Update the icon **from a state observer (Combine `objectWillChange` sink), not only the 3s timer** — the current timer means up to 3 s of stale icon after a click.

Accessibility: always pass a meaningful `accessibilityDescription` reflecting state, e.g. `"Kjol: Serving, always-on, fans auto"`.

## 3. Popover positioning & sizing — NSPanel vs NSPopover

Keeping **NSPanel** is right (known pitfall: NSPopover + NSHostingController + SwiftUI `@main` renders blank; also NSPanel avoids focus-steal via `.nonactivatingPanel`). Fixes to current implementation:

- **Positioning bug:** panel is placed by `setFrameTopLeftPoint` relative to window origin only — it can hang off the right screen edge. Compute: `x = min(buttonFrame.midX - panelWidth/2, screen.visibleFrame.maxX - panelWidth - 8)`, clamp left to `screen.visibleFrame.minX + 8`; `y = buttonScreenFrame.minY - 4` (use `btn.window!.convertToScreen(btn.convert(btn.bounds, to: nil))`).
- **Click-outside-to-dismiss:** current global monitor misses clicks *inside other windows of the same app* and doesn't catch Escape. Add a **local monitor** too (`addLocalMonitorForEvents`) that closes when the click target isn't the panel, plus `keyDown` local monitor for Escape (keyCode 53). Also close on `NSWindow.didResignKeyNotification` as a safety net.
- Drop `.titled/.closable` from styleMask → use `.borderless + .nonactivatingPanel` with rounded `NSVisualEffectView` mask (cleaner, no ghost titlebar), or keep titled but set `styleMask.remove(.resizable)`.
- `panel.animationBehavior = .utilityWindow` for correct show/hide animation.
- Don't call `NSApp.activate(ignoringOtherApps:)` — defeats the non-activating panel; call `panel.makeKeyAndOrderFront(nil)` only.
- Highlight the status item while open: `statusItem.button?.highlight(true)` on show, false on close (system apps do this; grounds the panel visually).

## 4. Visual Hierarchy — cards, spacing, typography

Current Card (16 pt padding, `.regularMaterial`, 12 pt radius, quaternary stroke) is good. Tighten:

- **Type ramp:** section headers = `.caption.weight(.semibold).foregroundStyle(.secondary)` UPPERCASED (System Settings pattern) instead of `.headline` + icon — saves height, reads as structure not content. Values/labels = `.body` or `.callout`; status = `.caption2.foregroundStyle(.secondary)`; never more than 3 levels visible per card.
- **Spacing grid:** 8 pt base. Card internal padding 12 (not 16), inter-card 10 (not 16), outer padding 14 (not 18). Arc/Linear-style compactness comes from disciplined 4/8/12 spacing, not smaller fonts.
- Corner radius 10 continuous; on macOS 26 consider `.background(.regularMaterial, in: .rect(cornerRadius:))` with `.glassEffect()` where available.
- Use monospaced digits for RPM/temps: `.monospacedDigit()` — prevents jitter while polling.
- Color semantics: orange = serving, red = max/error, green = confirmations only. Keep tint off neutral chrome.

## 5. Keyboard Shortcuts

- **Global hotkeys:** use the **KeyboardShortcuts** package (sindresorhus) — Carbon `RegisterEventHotKey` wrapper; no Accessibility permission needed (unlike `NSEvent.addGlobalMonitorForEvents`, which requires AX trust and only *observes*). Suggested defaults (all user-remappable, none pre-bound to avoid conflicts):
  - Toggle panel: ⌃⌥P
  - Kjol toggle: ⌃⌥⇧P
  - Cycle mode: ⌃⌥M
- **Local (panel open):** Escape closes; `1/2/3` select Normal/Serving/Max (`.keyboardShortcut("1", modifiers: [])`); ⌘Q quits; Tab cycles controls.
- Show a Notification (UserNotifications) when a global hotkey changes state while panel is closed — user needs feedback.

## 6. Accessibility

- Panel with `.nonactivatingPanel` + borderless can be invisible to full keyboard access — set `panel.becomesKeyOnlyIfNeeded = false` and ensure `canBecomeKey` returns true (subclass NSPanel) so VoiceOver/keyboard users can focus it.
- SwiftUI: add `.accessibilityLabel`/`.accessibilityValue` on the segmented picker ("Power kjol", value = mode) and toggles; group each card with `.accessibilityElement(children: .contain)`.
- Fan slider: `.accessibilityValue("\(Int(rpm)) RPM")`, `.accessibilityAdjustableAction`.
- Status item: dynamic `accessibilityDescription` (see §2). VO users reach it via VO+M M.
- Contrast: `.secondary` on `.regularMaterial` passes; avoid `.tertiary` for anything informational (current footer version string is fine, but the status line should be `.secondary` minimum). Red error text: use `.foregroundStyle(.red)` + icon, never color alone (add `exclamationmark.triangle`).
- Respect Reduce Motion: gate animations with `@Environment(\.accessibilityReduceMotion)`.
- Test with Reduce Transparency — materials become flat grey; the quaternary card stroke keeps structure legible.

## 7. Dark/Light Mode

- Template status icon: already handled (`isTemplate = true`). **Exception:** the red error icon must be non-template; provide it via palette symbol configuration and re-check on `NSApp.effectiveAppearance` change (`observe \.effectiveAppearance`).
- SwiftUI content: use only semantic styles (`.primary/.secondary`, `Color.accentColor`, materials) — no hardcoded hex. Current code complies.
- `NSVisualEffectView` `.material = .popover` (not `.windowBackground`) matches system popover chrome in both modes.
- Test matrix: light, dark, Reduce Transparency ×2, accent color variants, and "auto" wallpaper-driven menu bar tint (menu-bar appearance is wallpaper-dependent, not settings-dependent — another reason template images are mandatory).

## 8. Animations & Transitions

- Wrap state changes: `withAnimation(.spring(duration: 0.25))`; use `.animation(.smooth, value: host.state)` on the container.
- **Fan disclosure expand/collapse:** animate panel height — SwiftUI content height change + `panel.setContentSize` animated via `NSAnimationContext` (0.2 s, easeOut). HIG: "If you adjust the size of a popover, animate the change."
- Busy: replace disabling-everything with a per-control 35%-opacity + small `ProgressView` inline on the acted-upon control (per-operation busy tracking — a single global `busy` flag currently drops the 2nd/3rd chained Kjol command; queue them).
- Mode change confirmation: brief symbol effect on header bolt (`.symbolEffect(.bounce, value: mode)` on macOS 14+).
- Toggle confirmations (the green checkmark rows): `transition(.opacity.combined(with: .move(edge: .top)))`.
- Status-bar icon: crossfade by animating `alphaValue` of the button 1→0.6→1 over 0.15 s when swapping images.
- Respect Reduce Motion (§6).

## 9. Error Handling UX — helper & permissions

- **Helper status as a persistent footer chip**, not a buried button: `● Connected` (green) / `● Not installed — Install…` (orange, tappable) / `● Not responding — Retry` (red). Current UX hides install affordance among footer noise and shows raw error strings.
- Not-installed state: show a **setup card replacing controls** (not disabled controls with no explanation): icon + "Kjol needs a privileged helper to manage power settings. You'll be asked for an admin password once." + [Install Helper] button. Disabled-with-no-reason is the current biggest UX flaw.
- Error messages: human first line + expandable detail (`DisclosureGroup("Details")` with the raw osascript stderr). Never dump `installErr` raw.
- Helper unreachable while installed (XPC invalidated): auto-retry connect once, then red chip + "Retry" — don't hot-loop; 5 s poll already exists.
- Fan-control specific: on Apple Silicon manual fan writes can be reverted by `thermalmonitord`; if a write doesn't stick, show inline "System reclaimed fan control — reapplying…" rather than silently reverting the slider (state-revert-on-poll pitfall).
- Post-wake: re-apply fan override on `NSWorkspace.didWakeNotification`; show transient "Restoring fan settings…" caption.

## 10. Fan Control Integration

**Pattern: collapsed-by-default DisclosureGroup card (§1), TG Pro-inspired but simpler.**

- **Resting row:** `fanblades` icon + "Fans" + trailing `Auto · 1840 RPM` (secondary, monospaced digits) + chevron. Zero added cognitive load when unused.
- **Expanded:**
  ```
  FANS                       1840 RPM · 48°C
  [ Auto | Manual | Max ]          ← segmented, mirrors Power Kjol pattern
  Speed  ────────●──── 65%         ← slider, only visible in Manual
  ```
  - **Auto** = system control (default, safe). **Manual** = slider (percent of min–max RPM, per-fan collapsed into one slider unless fans differ). **Max** = one-click full blast for fans only (TG Pro's "Max" toggle is its most-used control).
  - Show live RPM + hottest sensor temp in the card header — gives the *why* for fan decisions without a separate sensors section.
- **Interlock with existing features:** "Kjol" macro also sets Fans → Max; leaving Max kjol returns fans to Auto (and say so in the Kjol tooltip). Keep fan mode otherwise independent of power kjol.
- Safety copy: when Manual < ~40% while temps high, caption warning "Low fan speed may cause throttling" (TG Pro does CPU-throttle warnings for low overrides).
- Status line (header) gains `fans: auto|manual|max`; icon badge per §2.
- Don't add per-fan tables, curves, or rules to the popover — that's settings-window territory (TG Pro keeps rule editing out of the menu). If curves come later, open a separate Settings window.

---

## Priority order (impact / effort)

1. Shrink layout: kill ScrollView, merge toggles, demote Kjol, 360 pt width (§1, §4)
2. Helper setup card + status chip (§9) — biggest first-run UX win
3. Positioning clamp + Escape/local-monitor dismissal + no `NSApp.activate` (§3)
4. Event-driven icon updates + state badges + a11y descriptions (§2, §6)
5. Fan DisclosureGroup card (§10)
6. Animations + per-operation busy queue (§8)
7. Global hotkeys via KeyboardShortcuts package (§5)

## Sources
- Apple HIG: Popovers, The Menu Bar, Segmented Controls — developer.apple.com/design/human-interface-guidelines
- Bjango, "Designing macOS menu bar extras" (22 pt working area, template images, 35% disabled opacity) — bjango.com/articles/designingmenubarextras
- TG Pro User Guide (fan System/Manual/Auto-Boost/Max modes, override warnings, first-launch popover) — tunabellysoftware.com/support/tgpro_tutorial
- iStat Menus 7 help (popover behavior, combined items) — bjango.com/help/istatmenus7
- AlDente (header macro buttons, right-click quick actions, live status icons) — apphousekitchen.com
- sindresorhus/KeyboardShortcuts (Carbon hotkey wrapper, no AX permission)
- StackOverflow 69877522 (NSPopover positioning), LinkedIn ntd4996 (NSPanel .nonactivatingPanel focus fix)
- Existing skill: `kjol-menubar-design` (NSPanel-over-NSPopover pitfall, busy-flag pitfall, SMC fan control per-chip notes)
