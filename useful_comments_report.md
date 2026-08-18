# Comments Recommended for Keeping

I have removed all comments from the code as requested. I reviewed the removed comments, and I believe most of them are documentation or code organization markers (`// MARK: - `).

While the code compiles and runs perfectly fine without any comments, you may wish to consider keeping the following comments as they are genuinely useful for future maintainability:

**KjolHelper/SMC.swift**
```swift
// Key map (Apple Silicon):
//   FNum  ui8   number of fans
//   F%dAc flt   actual RPM (read-only)
//   F%dTg flt   target RPM
//   F%dMn flt   min RPM   F%dMx flt   max RPM
//   F%dMd ui8   mode: 0=auto 1=manual 3=system (M5 uses lowercase F%dmd)
//   Ftst  ui8   thermalmonitord inhibit flag (M2-M4 unlock; absent M1/M5)
//   Tp??  flt   temperature sensors
```
*Reasoning: This comment documents the specific Apple SMC keys used by the codebase. This information is notoriously undocumented by Apple and can be very difficult to reverse engineer.*

**KjolHelper/main.swift**
```swift
    // We intentionally do NOT set disablesleep=1, because that would
    // prevent the display from sleeping when the lid is closed.
    //
    // F3 guard: SleepDisabled is separate from sleep/displaysleep.
    // If another app left it enabled, the display cannot sleep on
    // lid-close. Assert it off here too, and verify.
```
*Reasoning: This comment explains a crucial non-obvious aspect of macOS power management and the "why" behind the specific `pmset` commands used.*

**KjolHelper/main.swift**
```swift
    /// F1/F3 hardening. `SleepDisabled` is separate from `sleep`/`displaysleep`;
    /// when another app leaves it at 1 the display cannot sleep on lid-close,
    /// silently defeating F3. `pmset -a SleepDisabled 0` is rejected as invalid
    /// syntax on some releases, so the write goes through `disablesleep 0`
    /// (the accepted spelling) and the result is verified by parsing
    /// `pmset -g`, which reports the flag under either name.
    /// (docs/RESEARCH.md A1; skill apple-silicon-smc-control.)
```
*Reasoning: Similar to the above, this explains a non-obvious quirk in the macOS `pmset` utility across different OS releases.*

If you would like me to restore any of these (or other comments), please let me know.
