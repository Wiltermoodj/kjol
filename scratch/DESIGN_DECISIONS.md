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
