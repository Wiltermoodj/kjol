# Final Design Decisions (Frontier Mapping)

**Round 1 Decisions:**
1. **SMC Fan Mode Async Retry:** Implement caller-side async retry for `Ftst` unlock. Daemon returns immediate error; UI retries.
2. **State Cache Coherency:** Keep in-memory cache. Document the coherency contract in `KjolHelper/main.swift` explicitly prohibiting out-of-band external writes.
3. **Subprocess Timeout Logging:** Use `try` + logging (or explicit `do-catch`) in `shell()` wrappers instead of silently ignoring transient errors.

**Round 2 Decisions:**
4. **Redundant Signals:** Ensure `signal(SIGTERM, SIG_IGN)` and `SIGINT` are completely removed, relying solely on `DispatchSource`.
5. **Always-on Clamshell Assertion:** Keep the synchronous `assertSleepDisabledOff()` shell execution inside the XPC reply path for correctness and immediate UI feedback.
6. **Hardcoded Daemons List:** Extract the 20 hardcoded macOS daemons in `suspendNonEssentialDaemons()` into a configurable constant or plist.

**Round 3 Decisions:**
7. **Sync XPC API Blocking:** Keep `syncSetAlwaysOn` with `DispatchSemaphore`, but add explicit error logging if the 2.0s timeout is reached.
8. **NSLock in XpcClient:** Retain `NSLock` for synchronous state protection. Do not refactor to actors.
9. **Telemetry Polling Interval:** Increase `Host.swift` polling interval to 5.0 seconds.

**Round 4 Decisions (from sidecar files):**
10. **Battery Calibration State Machine:** Keep the 4-phase state machine but externalize hold durations as tunable constants.
11. **UpdateViewModel State Machine:** Add state transition logging via `os_log` to help debug state machine issues in production.
12. **Subprocess/Shell Error Handling:** Add explicit logging for `shell()` failures instead of swallowing them with `try?`.

These decisions successfully close out the gap analysis phase before code materialization.

**Round 5 Decisions (Feature Expansion - Code Quality & Testing):**
13. **Stale Test Files:** Update the stale manual test files (`mode-test.swift`, `xpc-test.swift`) to use the current protocol methods rather than deleting them. They serve as simple script-based log runners (using `print` instead of `XCTest`).
14. **XCTest Suite Integration:** Introduce a minimal SPM-based test target using a mock approach. Keep `build-kjol.sh` as the primary build mechanism, using SPM only for unit testing (via `swift test`).
15. **os_signpost Instrumentation:** Defer adding `os_signpost` to telemetry polling until specifically needed for profiling.
16. **Shared Module Location:** Keep `KjolHelperProtocol.swift` in `KjolHelper/`. Do not create a separate `Shared/` directory; the build script handles cross-compilation adequately.
17. **Unit Test Scope:** The SPM tests should primarily focus on pure logic components like `CpuSamplerService` and battery state calculations, avoiding XPC framework internals.
18. **SMC Mocking Strategy:** Use protocol-oriented dependency injection (`protocol SMCProvider`) for future SMC unit tests rather than `#if DEBUG` macros, ensuring production binaries remain clean.

**Round 6 Decisions (From Sidecar Files):**
19. **CpuSamplerService Structure:** Keep `CpuSamplerService` as-is. It has clear responsibilities and follows Swift conventions without needing further fragmentation.
20. **Host Reconnection Timers:** Keep separate retry timers for XPC reconnection and telemetry polling to decouple connection recovery (exponential backoff) from data refresh.
21. **Host Polling Interval:** Increase `Host.swift` polling interval to 5.0s to reduce CPU/battery overhead while keeping telemetry current enough for the UI.
22. **ViewModels Async Flow:** Keep the current `Task` + `@Published` approach for async data flow in `ViewModels`. SwiftUI's native async support is clean and correct for a macOS Apple-Silicon target.
23. **UpdateCheckerService Async Pattern:** Keep `Task` + `@Published` for async state updates in `UpdateCheckerService`. Wait to add debounce/equality guards for UI flicker until it becomes an observable issue.
24. **UpdateCheckerService State Machine:** Add state transition logging via `os_log` to help debug state machine issues in production.
25. **KjolHelperProtocol Organization:** Keep `KjolHelperProtocol` as-is. It is small and cohesive, and premature splitting would add abstraction cost without a demonstrated need.
26. **Battery Calibration State Machine (KjolHelperProtocol):** Keep the 4-phase state machine but externalize the hold durations as tunable constants to adapt to different hardware chemistries.
27. **UpdateViewModel State Machine:** Add state transition logging via `os_log` to improve production debuggability without altering runtime behavior.
28. **HelperInstaller Error Handling:** Replace `try?` with `try` + logging for SMC reads to surface failures for debugging while keeping the daemon alive.
29. **HelperInstaller Subprocess Error Handling:** Add explicit logging for `shell()` failures instead of silently swallowing them with `try?`, preserving daemon uptime while surfacing issues.
30. **XpcClient Sync API Blocking:** Keep the `DispatchSemaphore` wrapper for `syncSetAlwaysOn()` but add explicit error logging if the 2.0s timeout is hit to ensure failures aren't silently swallowed.
31. **XpcClient Lock Serialization:** Keep `NSLock` to protect the `stateCache` and connection state, as critical sections are short and synchronous.
32. **Main.swift Organization:** Keep `main.swift` as-is. It serves appropriately as the composition root, while delegating well-scoped concerns to `Host.swift`, `ViewModels.swift`, etc.
33. **Main.swift Fan Watchdog Strategy:** Keep the 5s periodic fan watchdog with a 12s asymmetric spin-down hold. This hysteresis prevents acoustic fan hunting while maintaining thermal responsiveness.

**Round 7 Decisions (Design Discovery Tree - Round 1):**
34. **SMC Mocking Strategy:** Agree. Protocol injection ensures clean separation of concerns without cluttering the production SMC layer.
35. **CpuSamplerService Structure:** Keep as-is. It has a focused single responsibility, and adding indirection would hurt readability without clear gain.
36. **XPC Client Sync API Blocking:** Keep the sync wrapper with error logging. It's pragmatic for callers that cannot use async, and logging prevents silent failures.
37. **Battery Calibration State Machine:** Externalizing hold durations adapts to different hardware chemistries while keeping the proven 4-phase pattern.
38. **UpdateCheckerService State Machine:** Adding `os_log` is a low-risk observability improvement that aids troubleshooting without altering runtime behavior.

**Round 8 Decisions (Design Discovery Tree - Round 2):**
39. **HelperInstaller Error Handling:** Logging preserves safety and daemon uptime while surfacing transient hardware/command failures for diagnostics.
40. **XpcClient Lock Serialization:** `NSLock` remains appropriate for short synchronous sections; actors would add unneeded complexity here.
41. **Adaptive Fan Watchdog Strategy:** This provides the right balance for a root daemon, minimizing SMC read load while effectively preventing acoustic hunting.
42. **Host Polling Interval & Retry Timers:** 5.0s polling reduces overhead, and separate timers prevent backoff interference between connection recovery and data refresh.
43. **ViewModels Async Flow:** It aligns perfectly with modern SwiftUI patterns and avoids unnecessary Combine boilerplate.

**Round 9 Decisions (Design Discovery Tree - Round 3):**
44. **Main.swift Organization:** The project already delegates concerns well; `main.swift` acts as a clean composition root. Premature refactoring adds complexity.
45. **UpdateViewModel Async State Updates:** Keep the native pattern to minimize maintenance burden, as there is no current evidence of flicker requiring caching.
46. **KjolHelperProtocol Organization:** Premature splitting would add abstraction cost without a demonstrated need for independent reuse.
47. **Feature Expansion Process:** Acknowledge that Feature Proposals (Doc-Gap, Infrastructure Extension, Architecture Inference) generated in sidecars are NOT immediate ADRs, but proposals requiring explicit human review before implementation. This maintains the rule that agents propose and humans decide, preventing uncontrolled scope creep.
