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
