# Kjol

A native macOS menu-bar utility for power management on Apple Silicon Macs.

## Overview

Kjol is a standalone application that provides fine-grained control over system power management, always-on behavior (lid closed), and background daemon suspension. It does NOT require a terminal window to run and lives entirely in the macOS status bar.

## Features

- **Power Kjol** — Three modes: Normal (macOS defaults), Serving (kept awake), Max (aggressive optimizations)
- **Always-On** — Keep the system awake even with the lid closed (caffeinate + pmset)
- **Daemon Suspension** — Suspend non-essential background daemons (Spotlight, media analysis, etc.)
- **Full Blast** — One-click toggle for all optimizations

## Architecture

Kjol uses a **privileged helper** architecture for root-level operations:

```
Kjol.app (menu-bar, runs as user)
    └── XPC → com.lappier.kjol.helper (LaunchDaemon, runs as root)
                    ├── pmset commands (power modes)
                    ├── caffeinate (always-on)
                    ├── pkill (daemon suspension)
                    └── mdutil (Spotlight control)
```

The app communicates with the helper via XPC. The app and helper are packaged together in a single macOS installer package (`Kjol.pkg`). Installing `Kjol.pkg` prompts once for administrator authorization, places `Kjol.app` in `/Applications`, installs and bootstraps the LaunchDaemon, and automatically starts Kjol in the menu bar.

## Features

### Power & Battery
- **Always-On (Clamshell)** — Keeps the system awake with lid closed (`pmset disablesleep 1` + `caffeinate`)
- **Pause Indexing Daemons** — Suspend/resume non-essential background daemons (Spotlight, mediaanalysisd, photoanalysisd, etc.)
- **Charge Limit** — Set hardware battery charge threshold (e.g. 80%) via SMC (`BCLM`/`CH0C`)

### Native Fan Control (no third-party apps)
- **Profiles:** Auto (system control), Quiet, Balanced, Blast, Custom (0–100% slider)
- **Live telemetry:** Per-fan actual and target RPMs, P-Core & E-Core CPU load, SoC/CPU/GPU temperatures
- **Self-healing:** If firmware reclaims fans on sleep/wake, the helper maintains the saved profile

### Status Bar
- **Icon states:** `bolt` (idle), `fan.fill` (manual fans), `bolt.horizontal.icloud.fill` (busy), `exclamationmark.octagon.fill` (error)
- **Always-on indicator:** Accent tint when Always-On is active
- **Live tooltip:** Mode · temperature · fan RPMs · always-on state

## Building & Installation

### Single-File Installer (Kjol.pkg)

```bash
cd /Users/lappier/code/projects/kjol
./build-kjol.sh          # Builds Kjol.pkg in the project directory
```

Double-click `Kjol.pkg` (or distribute it). The installer will:
1. Install `Kjol.app` into `/Applications/`
2. Install `com.lappier.kjol.helper` into `/Library/PrivilegedHelperTools/`
3. Install and bootstrap the LaunchDaemon in `/Library/LaunchDaemons/`
4. Automatically launch `Kjol.app` in your menu bar

### Opening `Kjol.pkg` on macOS (Gatekeeper Guidance)

Since Kjol uses ad-hoc signing (`-s -`) without an Apple Developer ID certificate, macOS Gatekeeper may present an "Unidentified Developer" dialog on initial installation.

**Steps for Non-Technical Users:**
1. **Method A (Quickest):** Right-click (or Control-click) `Kjol.pkg` in Finder → Select **Open** → Click **Open** in the prompt.
2. **Method B (System Settings):** Open **System Settings** → **Privacy & Security** → Scroll down to **Security** → Click **Open Anyway** next to `Kjol.pkg`.

### In-App Updates

Kjol features direct background updates via GitHub Releases (`Wiltermoodj/kjol`):
- **Automatic Checking:** Silently checks for updates when the menu bar popover opens (throttled to once per hour).
- **Manual Checking:** Click "Check for Updates" in the popover footer.
- **One-Click Upgrade:** When an update is available, click **Update Now** to download `Kjol.pkg` in the background and launch the installer GUI.

### Direct Terminal Install

```bash
./build-kjol.sh --install    # Build and install directly
```

### Uninstallation

```bash
./uninstall-kjol.sh          # Or: ./build-kjol.sh --uninstall
```

## Project Structure

```
kjol/
├── build-kjol.sh          # Unified build and packaging script (generates Kjol.pkg)
├── uninstall-kjol.sh      # Complete uninstaller script
├── Kjol/
│   ├── main.swift            # Menu-bar UI (SwiftUI popover)
│   ├── Host.swift            # State coordinator & polling
│   ├── ViewModels.swift      # Telemetry, fan control & power view models
│   ├── XpcClient.swift       # Resilient XPC connection client
│   ├── HelperInstaller.swift # Diagnostic helper verification
│   ├── CpuSamplerService.swift # P/E Core CPU sampler
│   ├── Info.plist            # App bundle metadata
│   └── helper.plist          # Helper LaunchDaemon plist
├── KjolHelper/
│   ├── main.swift            # Privileged helper daemon (XPC server, root operations)
│   ├── SMC.swift             # Native AppleSMC IOKit driver & battery controls
│   ├── KjolHelperProtocol.swift # Shared XPC protocol definition
│   └── Info.plist            # Helper metadata
└── build/                    # Build output and packaging staging
```

## Power Modes

| Mode | Sleep | Low Power | Spotlight | Caffeinate | Daemons |
|------|-------|-----------|-----------|------------|---------|
| Normal | On | On | On | Off | Running |
| Serving | Off | Off | On | On | Running |
| Max | Off | Off | Off | On | Suspended |

## Always-On (Lid Closed)

On Apple Silicon Macs, the system normally sleeps when the lid is closed. Kjol's always-on mode prevents this by:

1. Setting `pmset disablesleep 1` — the only reliable way to prevent clamshell sleep on Apple Silicon (firmware-level; `sleep 0` + `caffeinate` alone are insufficient)
2. Setting `pmset sleep 0` and `hibernatemode 0`
3. Running `caffeinate -u -i -s` (prevent idle/system sleep)

On Intel Macs, `pmset sleep 0` + `caffeinate` is sufficient. The `disablesleep` key is harmless on Intel.

## Fan Control (Native SMC)

Kjol controls fans natively via the AppleSMC IOKit driver — no third-party apps.

- Profiles: Auto (system control), Quiet (25%), Cool (60%), Blast (100%), Custom (0-100% slider)
- Live per-fan RPM bars + SoC temperature readout in the popover (3s polling)
- Percent maps linearly min→max RPM per fan; manual mode = SMC `F%dMd=1` + `F%dTg`
- M1/M5: direct mode writes; M2-M4: automatic `Ftst` unlock fallback; M5 lowercase `F%dmd` handled
- Self-healing: if firmware reclaims fans (sleep/wake), the helper re-applies the saved profile on next poll
- Reads are unprivileged; writes go through the root helper

## Future Work


- **Code signing** — Currently ad-hoc signed. Will add Developer ID signing when available.

## Related

- [LLMControl Orphan](../LLMControl-orphan) — Extracted model management logic
- Original `llmctl` script at `/opt/homebrew/bin/llmctl`
