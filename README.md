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

The app communicates with the helper via XPC. The helper is installed seamlessly via macOS's built-in SMAppService daemon manager, requiring only a single admin authentication prompt the first time you enable it through the "Install Privileged Helper" button. Once installed, no further prompts are needed.

## Features

### Power Kjol
- **Normal** — macOS defaults (low power mode on, sleep enabled)
- **Serving** — low power off, stays awake
- **Max** — aggressive (daemons paused, always-on)

### Native Fan Control (no third-party apps)
- **Profiles:** Auto (system control), Quiet (25%), Cool (60%), Blast (100%), Custom (0–100% slider)
- **Live telemetry:** per-fan RPM bars, animated, orange when manually controlled
- **Sparkline:** rolling ~3-minute RPM history graph (per-fan colored lines)
- **SoC temperature** readout with heat coloring (green/yellow/red)
- **Keyboard shortcuts** (panel open): ⌘1–⌘5 = fan profiles, Esc = close
- **Self-healing:** if firmware reclaims fans on sleep/wake, the helper re-applies the saved profile

### Always-On (Lid Closed)
- `pmset disablesleep 1` + `caffeinate -u -i -s` — Apple Silicon clamshell sleep prevention
- Restored to defaults on disable

### Background Daemons
- Suspend/resume non-essential daemons (Spotlight indexing, media analysis, etc.)

### Status Bar
- **Icon states:** `bolt` (idle), `bolt.circle` (serving), `bolt.fill` (max), `fan.fill` (manual fans), `exclamationmark.octagon.fill` (error), `bolt.horizontal.icloud.fill` (busy)
- **Always-on indicator:** blue tint on the icon
- **Live tooltip:** mode · temperature · fan RPMs · always-on state

## Building

```bash
cd /Users/lappier/code/projects/kjol
./build-kjol.sh          # Build only
./build-kjol.sh --install  # Build and install to /Applications/
```

## Installation

1. Build and install: `./build-kjol.sh --install`
2. Launch: `open /Applications/Kjol.app`
3. Click the bolt icon in the status bar
4. Click "Install Privileged Helper" and enter admin credentials
5. Once installed, all controls are active

## Project Structure

```
kjol/
├── build-kjol.sh          # Build script
├── Kjol/
│   ├── main.swift            # Main app (menu-bar, XPC client)
│   ├── Info.plist            # App metadata (LSUIElement, SMPrivilegedExecutables)
│   └── helper.plist          # Helper LaunchDaemon plist (copied to bundle)
├── KjolHelper/
│   ├── main.swift            # Privileged helper (XPC server, root operations)
│   ├── KjolHelperProtocol.swift  # Shared XPC protocol
│   └── Info.plist            # Helper metadata
└── build/                    # Build output
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
