# AGENTS.md

Developer, Agent, and Contributor guide for building, testing, packaging, versioning, and releasing Kjol.

---

## Project Overview & Architecture

Kjol is a native macOS menu bar utility for Apple Silicon power management and hardware control. Root-level operations are delegated from the unprivileged user menu-bar app to a privileged helper tool via XPC.

```
Kjol.app (menu-bar, runs as user)
    └── XPC → com.lappier.kjol.helper (LaunchDaemon, runs as root)
                    ├── pmset commands & caffeinate (always-on clamshell)
                    ├── SMC hardware driver (fan control & charge limit)
                    ├── pkill (daemon suspension)
                    └── mdutil (Spotlight control)
```

---

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

---

## Building & Local Development

### Build Single-File Installer (`Kjol.pkg`)

```bash
./build-kjol.sh
```

### Direct Terminal Build & Install

Builds the application and privileged helper, stages the package, and installs/starts it locally:

```bash
./build-kjol.sh --install
```

### Uninstallation

Remove all installed components (`Kjol.app`, helper tool, launch daemon, and preferences):

```bash
./uninstall-kjol.sh
# or
./build-kjol.sh --uninstall
```

---

## Versioning & Publishing Releases

Kjol features in-app auto-updates driven by GitHub Releases (`Wiltermoodj/kjol`). When cutting a release:

1. **Bump Version in `Kjol/Info.plist`:**
   ```bash
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.1" Kjol/Info.plist
   /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1.0.1" Kjol/Info.plist
   ```

2. **Rebuild Installer Package:**
   ```bash
   ./build-kjol.sh
   ```
   *(Automatically embeds the version from `Kjol/Info.plist` into `Kjol.pkg`)*

3. **Commit, Tag, and Push:**
   ```bash
   git commit -am "Bump version to v1.0.1"
   git tag v1.0.1
   git push origin main --tags
   ```

4. **Publish GitHub Release via `gh`:**
   ```bash
   gh release create v1.0.1 ./Kjol.pkg \
     --repo Wiltermoodj/kjol \
     --title "Kjol v1.0.1" \
     --notes "Description of changes, enhancements, or bug fixes."
   ```

---

## Technical Details

### Always-On (Lid Closed)
- Spawns `caffeinate -u -i -s` from the root helper daemon.
- Configures power management via `pmset -a lowpowermode 0 powernap 0 sleep 0 displaysleep 10 disksleep 0 standby 0 hibernatemode 0 ttyskeepawake 1 lessbright 0`.
- Preserves always-on state across helper restarts and reboots until toggled off.

### Fan Control (AppleSMC)
- Direct SMC hardware manipulation via IOKit driver.
- Supports Auto, Quiet (25%), Cool (60%), Blast (100%), and Custom (0–100%) slider.
- M1/M5: direct mode writes; M2–M4: automatic `Ftst` unlock fallback; M5 lowercase `F%dmd` handled.
- Helper auto-recovers fan profile if system firmware resets SMC state on sleep/wake.
- Unprivileged reads for telemetry; privileged writes through root helper.
