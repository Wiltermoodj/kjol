# Kjol — Research Findings

Inspection-only loop. Every finding here is sourced; nothing in this document was
verified by launching Kjol (launching is forbidden in this loop). Claims are
therefore about **what the code should be**, verified by reading the code, not
about runtime behaviour.

Primary source for F1/F2/F3: the `apple-silicon-smc-control` skill
(`/Users/lappier/.hermes/skills/apple/apple-silicon-smc-control/SKILL.md`),
whose contents are recorded as VERIFIED WORKING on M1 Max (MacBookPro18,4),
macOS 26, against the reference implementation at `KjolHelper/SMC.swift`.

---

## F1 — Keep the Mac awake (always-on)

**Finding (apple-silicon-smc-control, "Always-on with lid closed (clamshell)"):**
On Apple Silicon, clamshell sleep is **firmware-level**. `pmset sleep 0` and
`caffeinate` are *not sufficient by themselves* in the general case, and
`pmset -a disablesleep 1` *does* hold the system awake lid-closed but also blocks
the display from sleeping — which directly contradicts F3.

The recipe recorded as correct for "system awake + display allowed to sleep" is:

```
sleep 0
displaysleep 5..10      (a NORMAL timeout, never 0)
hibernatemode 0
ttyskeepawake 1
+ caffeinate -u -i -s   (spawned via Process, handle retained so it can be killed)
```

**Current state in code — matches.** `KjolHelper/main.swift`
`setAlwaysOn(true)` runs exactly `sleep 0` / `displaysleep 10` /
`hibernatemode 0` / `ttyskeepawake 1` and then `startCaffeinate()`,
which installs and kickstarts a system LaunchDaemon labeled
`com.lappier.kjol.caffeinate` running `/usr/bin/caffeinate -u -i -s`
under launchd (`KeepAlive=true`). Teardown (`stopCaffeinate`) removes the
job so `caffeinate` does not outlive always-on.

**Residual risk (documented, not yet code-guarded):** `SleepDisabled` is a
*separate* system-wide flag. Per the skill's pitfall note, `SleepDisabled=1`
blocks lid-close display-off regardless of `disablesleep` or `caffeinate`, and
`sudo pmset -a SleepDisabled 0` can be rejected as invalid syntax — the working
form is `pmset -a disablesleep 0`, verified with
`pmset -g | grep -iE 'SleepDisabled|disablesleep'`. Kjol already issues
`disablesleep 0` on the always-on *disable* path (line 147) but does **not**
assert it on the *enable* path, so a `SleepDisabled=1` left behind by another
app would silently defeat F3. Tracked as a hardening item.

---

## F2 — Keep processes running with the lid closed — **VERDICT: hold-only**

**Question:** does Kjol need an IOKit clamshell/lid-state listener to keep
processes alive when the lid closes, or is the F1 pmset+caffeinate hold
sufficient on its own?

**Verdict: hold-only. No listener is warranted.** Rationale:

1. **The hold is the mechanism; the lid event is not.** Per
   `apple-silicon-smc-control`, the F1 recipe "keeps the system awake with the
   lid closed while still letting the display turn off." Processes keep running
   because the *system* never sleeps — that is a continuous state held by
   `caffeinate -u -i -s` plus the pmset settings, not something that must be
   re-armed in response to a lid transition. A listener would observe an event
   that requires no action.

2. **A listener adds a wake-path failure mode without adding capability.** The
   only thing a lid-close callback could do is re-apply a hold that is already
   applied. If the hold is correct, the callback is a no-op; if the hold is
   broken, the callback fires too late (the system is already sleeping) to fix
   it. It cannot rescue the failure case it would exist for.

3. **The lightweight invariant forbids the cheap version of it.** Reading
   `AppleClamshellState` off `IOPMrootDomain` on a schedule would mean a poll,
   and PRIORITIES.md bans any Timer faster than the existing 15s idle cadence.
   An event-driven `IOServiceAddInterestNotification` avoids the poll but costs
   a notification port, a run-loop source, and a teardown path in an app whose
   entire spec is "low compute, low memory" — real complexity for zero
   behavioural gain.

4. **The real fragility is elsewhere and is already handled.** The documented
   sleep/wake hazard on this platform is that *firmware reclaims the fans* after
   sleep/wake, not that processes die. The skill's prescribed fix is
   self-healing on the existing status poll: "if saved profile is manual but any
   fan mode != 1, silently re-apply setManual." Kjol already does this in
   `getFanStatus` (`KjolHelper/main.swift` lines 264–269), reusing the poll
   that already exists rather than adding a listener.

**Consequence for the code:** F2 is satisfied by F1's hold. The decision is
recorded here and cross-referenced from a comment on the always-on path so a
later reader does not "fix" the missing listener.

**Residual risk:** with no lid-state read, Kjol cannot *display* whether the
lid is currently closed. That is a UI nicety, not a keep-alive requirement, and
it is explicitly out of scope for the five features.

---

## F3 — Allow the screen to turn off with the lid closed

**Finding (apple-silicon-smc-control):** the two settings that break this are
`disablesleep 1` and `displaysleep 0`. The skill states plainly: "Do NOT use
`displaysleep 0` for always-on; that forces the screen to stay on," and
`disablesleep 1` "prevents the display from sleeping when the lid is closed."

**Current state in code — correct.** Grep across `Kjol/main.swift` and
`KjolHelper/main.swift` finds no `disablesleep 1` and no `displaysleep 0`;
the always-on path sets `displaysleep 10` and the normal-mode reapply sets
`displaysleep 10` (line 162). The only `disablesleep` write is `disablesleep 0`
on the disable path, which is the *correcting* direction.

**Protection:** this is a property that a future edit could silently regress, so
it is enforced statically — `check-kjol-design.sh` fails if either literal
appears in the always-on/lid paths. That check currently passes.

---

## F4 — Per-core CPU usage + SoC temperature

**Current state:** SoC temperature implemented (`KjolHelper/SMC.swift`
`socTemperature()`, `Tp*` scan, 5–130 °C filter, max). **Per-core CPU sampling
is now IMPLEMENTED** — `CpuSampler` / `CpuState` in `Kjol/main.swift`
(~lines 196–322), driven from `Host.sampleCpu()` called by the existing
`refresh()` on the single poll timer.

### Findings

**1. API choice — `PROCESSOR_CPU_LOAD_INFO`, not `HOST_CPU_LOAD_INFO`.**
`host_statistics(..., HOST_CPU_LOAD_INFO, ...)` returns a single
`host_cpu_load_info_data_t` with 4 aggregate tick counters — cheap, but it
averages away the exact signature this project cares about (one core pinned at
100% while the mean reads idle). `host_processor_info(mach_host_self(),
PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &count)` returns
`ncpu * CPU_STATE_MAX` integers, one group per logical core. This is the call
`htop` uses for per-CPU stats. The extra cost is one Mach RPC returning a few
hundred bytes; at a 3–15 s cadence it is negligible.
Refs: <https://developer.apple.com/documentation/kernel/1502854-host_processor_info>,
<https://opensource.apple.com/source/xnu/xnu-792/osfmk/mach/processor_info.h.auto.html>,
<https://www.green-coding.io/blog/cpu-utilization-mac/>

**2. Indexing.** Per-core state `s` of core `i` is at
`info[CPU_STATE_MAX * i + s]`, with `s` ∈ {`CPU_STATE_USER`,
`CPU_STATE_SYSTEM`, `CPU_STATE_NICE`, `CPU_STATE_IDLE`}.
`busy = user + system + nice`, `total = busy + idle`, utilisation = `busy/total`.

**3. Deltas are MANDATORY.** The counters accumulate monotonically since boot,
so absolute values describe the machine's entire uptime rather than "now". Only
`(busy ticks elapsed) / (total ticks elapsed)` between two samples is
meaningful. The first sample therefore has no predecessor: `CpuSampler.sample()`
returns `nil` and the UI shows "Sampling…" (`CpuState.hasSample == false`)
rather than fabricating a value from absolute counters — the common bug in the
widely-copied StackOverflow version, which reports a boot-averaged number on
first tick.
Ref: <https://stackoverflow.com/a/6795612>

**4. `vm_deallocate` is MANDATORY — this is the classic leak in this API.**
The kernel `vm_allocate`s a FRESH buffer on every `host_processor_info` call and
transfers ownership to the caller. A sampler that keeps the previous buffer for
delta arithmetic must free it before overwriting the pointer:
`vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev),
vm_size_t(MemoryLayout<integer_t>.stride * Int(prevCount)))`. `CpuSampler`
does this in `releasePrev()`, called both from `sample()`'s `defer` and from
`deinit`, so exactly one buffer is retained between ticks and nothing
accumulates. Note `MemoryLayout<integer_t>.stride`, not `.size` (same rule the
`apple-silicon-smc-control` skill states for the SMC param struct).

**5. Apple Silicon core ordering.** `host_processor_info` enumerates logical
CPUs with Performance cores first, then Efficiency cores. The split is read from
`hw.perflevel0.logicalcpu` (perflevel0 = "Performance", perflevel1 =
"Efficiency") via `sysctlbyname`; `CpuSampler.pCoreCount` caches it once at init
(topology is static) and the UI labels cores `P0…Pn` / `E0…En` accordingly,
falling back to `C0…Cn` if the sysctl is unavailable.
Ref: <https://developer.apple.com/documentation/kernel/1387446-sysctlbyname/determining_system_capabilities>

**6. Pitfalls handled.**
- *Leak*: see (4).
- *Counter wraparound*: tick counters are unsigned in the kernel but surface as
  `integer_t` (Int32). Subtracting them as `Int32` produces a large negative
  spike on wrap; `sample()` converts via `UInt32(bitPattern:)` and uses `&-`, so
  a wrap yields the correct small delta.
- *Cores going offline*: if the reported core count changes between ticks the
  delta would be index-misaligned, so the sampler returns `nil` for that tick
  and re-baselines instead of emitting nonsense.
- *Divide-by-zero*: `total == 0` (no ticks elapsed) yields 0, not NaN.

**7. Lighter alternatives considered and rejected.** `HOST_CPU_LOAD_INFO` is
cheaper but aggregate-only — rejected, see (1). Shelling out to `top`/`ps` costs
a process spawn per tick, orders of magnitude more expensive than one Mach RPC —
rejected. `IOReport`/`powermetrics` give richer per-cluster power data but
require root or a subprocess — rejected as far too heavy for a menu-bar poll.

### Lightweight compliance
No new `Timer` (sampling is a call inside the existing `refresh()`); rolling
`averageHistory` capped at 60 samples, matching `FanState.history`; per-tick
allocation is one `[Double]` of `ncpu` elements; the UI draws via the existing
`Shape`-based `ProportionCapsule`/`Sparkline` primitives, adding no
proxy-closure layout, immediate-mode drawing view, or animation modifier.

---

## F5 — Lightweight UI (no redraw storms)

**Finding (kjol-menubar-design + in-repo state):** the original heat suspect
was two `GeometryReader` views recomputing a `Path` on every `@Published` tick,
with the panel staying allocated while hidden — a hidden redraw loop.

**Current state — resolved.** Both proxy closures are gone. Geometry now lives
in `Shape` types: `SparklineShape` (line 718) and `ProportionCapsule`
(line 750). The rationale is captured in the code comment at lines 712–717: a
`Shape`'s `path(in:)` is evaluated by the layout system only when the view is
actually rendered at a size, so a hidden panel does not recompute it per tick.
Animation modifier count is 0. History remains capped at 60
(`refreshFans`, lines 605 and 608).

---

## Discovery — items the five-feature plan did NOT consider

An open-ended discovery pass is mandated before the loop may report "feature
contract satisfied." Below are the candidate items raised so far from the
preloaded skills and from reading the code, with an adopt/reject disposition.
Items marked *pending* await the discovery sub-agent's citations and must not be
promoted to `Fx` win-conditions until sourced.

### Adopted

- **A1 — `SleepDisabled` read-back guard on the always-on path.**
  Source: `apple-silicon-smc-control` pitfall note (see F1 above). The plan
  assumed `caffeinate` + pmset was the whole story; a stray `SleepDisabled=1`
  from another app defeats F3 and nothing in Kjol corrects it when always-on
  is *enabled*. Cheap, code-verifiable (grep for a `disablesleep 0` write on the
  enable path). Adopted as a hardening item under F1.

- **A2 — Record the F2 hold-only decision in code, not only in docs.**
  The absence of a listener is indistinguishable from an oversight to a future
  reader, who may "fix" it by adding a poll and break the lightweight
  invariant. A comment on the always-on path pointing at this document makes
  the decision durable. Code-verifiable by grep.

### Rejected

- **R1 — IOKit clamshell listener (`AppleClamshellState` /
  `IOServiceAddInterestNotification`).** Rejected; see the F2 verdict above.
  Adds a notification port, run-loop source, and teardown path for no
  behavioural gain, and the polling variant is banned by the lightweight
  invariant.

- **R2 — `pmset -a disablesleep 1` as the always-on mechanism.** Rejected: it
  works for keep-awake but blocks lid-closed display sleep, directly violating
  F3. Explicitly called out as wrong in `apple-silicon-smc-control`.

- **R3 — A dedicated faster timer for CPU sampling.** Rejected by the
  lightweight invariant before it was proposed: F4 must reuse the existing poll
  timer. Recorded here so the option is visibly closed rather than merely
  unmentioned.

### Pending (await discovery sub-agent citations)

- Whether updating the `NSStatusItem` button image or a `@Published` property
  while the panel is closed still triggers SwiftUI body evaluation, and whether
  work should be skipped entirely when hidden.
- `Timer.tolerance` as a timer-coalescing energy win at the 15s idle cadence.
- QoS class / App Nap interaction for a background poller.
- Restoring pmset settings if the helper dies or the app crashes while
  always-on is active (currently only the explicit disable path restores them).
- `IOPMAssertionCreateWithName` as a native in-process alternative to spawning
  `caffeinate` (noted in `kjol-menubar-design` §10.1).

These are recorded as open questions, not as findings. None has been promoted to
a win-condition and none has been implemented.

## F6 — SleepDisabled read-back guard (worker addition, 2026-08-08)

**Finding.** `SleepDisabled` is a system-wide flag independent of `sleep` and
`displaysleep`. While it is 1, the display cannot sleep on lid close no matter what
else the always-on path sets — so F3 (lid-closed screen-off) is silently defeated by
any *other* app that set it. `sudo pmset -a SleepDisabled 0` can be rejected as
invalid syntax; `pmset -a disablesleep 0` is the spelling that takes, and `pmset -g`
reports the state under either name.
Source: skill `apple-silicon-smc-control` — "Pitfall: SleepDisabled is a separate
system-wide flag", which explicitly prescribes verifying with
`pmset -g | grep -iE 'SleepDisabled|disablesleep'`.

**Why the pre-existing code was insufficient (not a guess — read at KjolHelper/main.swift).**
The enable path called `runPmset(["-a","disablesleep","0"])`, and `runPmset` discards
failure to stderr. Write-only. Nothing ever confirmed the post-condition, and the reply
string claimed success unconditionally.

**Adopted.** Write-then-verify in `assertSleepDisabledOff()`: issue the accepted-spelling
write, parse `pmset -g`, return `(ok, detail)`. Absent flag is treated as off. The result
is persisted (`sleep_disabled_ok` / `sleep_disabled_detail`) and returned in helper status;
on failure the reply reports partial success — the F1 awake-hold IS applied, only the F3
screen-off guarantee is unverified.

**Rejected.** (a) Polling the flag on the status tick — would add per-tick `pmset -g`
subprocess spawns, violating the lightweight invariant for a value that only changes when
some app writes it. (b) Failing the whole enable when the guard fails — the awake-hold
genuinely did apply; reporting total failure would be less accurate than the partial
message. (c) `SleepDisabled` as the write spelling — rejected on the cited syntax pitfall.

**Lightweight impact.** Zero new timers, zero new state observers; one extra `pmset -g`
per user-initiated always-on enable. Asserted by checker ("F6 guard adds no timer").

## Infrastructure defect found this iteration: sandbox stderr written INTO source files

Under the loop's `sandbox-exec` profile, a denied write to the harness cwd-tracking temp
and that line was being **appended into edited files themselves**. Measured at the start of
this iteration: `Kjol/main.swift` = 7 such lines, `KjolHelper/main.swift` = 4,
`check-kjol-design.sh` = 1. The checker actually exited 127 because of it.

This is a REAL build-breaker that inspection-only iterations can miss: the lines are not
Swift, and the checker's greps do not look for them, so 13/13 green coexisted with a corrupt
source file. Most of the pollution predates this iteration.

Remediation applied: stripped all matching lines from the three files; re-verified brace and
paren balance = 0 for both Swift files and `bash -n` clean for the checker.
**Recommended follow-up requirement:** add a checker assertion that no tracked source file
contains `Operation not permitted`, so this class cannot silently return.

## F8 — pollution guard widened to docs + progress logs (worker addition, 2026-08-08)

**Finding (measured, not inferred).** The sandbox-stderr injection that F7 was created to
catch is NOT confined to Swift sources. At the start of this iteration `docs/RESEARCH.md`
carried 1 injected line and `kjol/loop_progress.log` carried 2 — while F7 reported 0
polluted files and the whole suite was 17/0 green. F7 scans `*.swift` only.

**Why this is a real defect class, not tidying.** An inspection-only loop produces exactly
two durable artifacts: the progress log (its audit trail) and this research document (the
evidence base under every "research-backed" claim). Corrupting either is the inspection-loop
equivalent of a build break. It is also actively hostile to editing: two `patch` calls this
iteration failed post-write verification ("wrote 8954 chars, read back 9075") because the
sandbox appended a stderr line into the target file between the write and the read-back. The
edits had in fact landed; the diff was the pollution itself.

**Adopted.** A second assertion (F8) scanning `docs/*.md`, both `loop_progress.log`s and
`PRIORITIES.md`. Its regex is intentionally stricter than F7's bare substring match, anchoring
on `^/bin/bash: line <N>: ...hermes-cwd-<hex>.txt: Operation not permitted`. This matters: a
bare-substring version would match this very paragraph and render the check permanently and
unfixably red — a guard that cannot go green teaches the loop to ignore it.

**Rejected.** (a) Widening F7's existing regex to all file types — it would self-match the
documentation above. (b) Auto-stripping pollution from inside the checker — a checker that
repairs what it measures can never fail, which is the paper-control shape. Detection and
remediation stay separate.

**Mutation-verified.** Injecting one synthetic polluted line into `kjol/loop_progress.log`
flipped the suite 18/0 -> 17/1; removing it returned 18/0. The assertion has been shown to
fail on the defect it names.

**Collateral fix.** `$OVERSEER` was referenced by the new check but never defined in
`check-kjol-design.sh`; under bash without `set -u` it expands to empty, so two of the four
scanned paths would have silently resolved to `/PRIORITIES.md` and been skipped. Defined at
line 15 next to `$REPO`. This is the same class of silent-no-op guard the overseer skill warns
about, found in the guard added minutes earlier.

## Mutation verification of the F1–F4 assertions (worker addition, 2026-08-08)

Prior iterations proved F7 and F8 by mutation but left F1–F4 unproven: an assertion
that has never been observed to FAIL is not yet demonstrated to be a control. This
iteration drove each one negative against a throwaway copy of the sources at
`kjol-overseer/build/mut/kjol` (the live tree was never mutated; the checker
was re-pointed via its `REPO=` line).

| # | Mutation applied | Expected | Observed |
|---|---|---|---|
| M1 | `caffeinate -u -i -s` → `-i` | F1 fails | FAIL `f1=0 hb=ok tk=ok` (17/1) |
| M2 | `hibernatemode 0` → `3` | F1 fails | FAIL `hb=missing` (17/1) |
| M3 | `ttyskeepawake 1` → `0` | F1 fails | FAIL `tk=missing` (17/1) |
| M4 | inject `displaysleep 0` | F3 guard fails | FAIL `got '1' want '0'` (17/1) |
| M5 | remove `host_processor_info`/`PROCESSOR_CPU_LOAD_INFO` | F4 fails | FAIL `got 'no'` (17/1) |
| M6 | add a 3rd 0.5s repeating timer | timer + F4-no-new-timer fail | FAIL x2 `got '3' want '2'` (16/2) |
| M7 | strip clamshell evidence from code AND docs | F2 fails | FAIL `got 'none'` (17/1) |
| M8 | strip the in-code F2 decision, KEEP docs prose | F2 should fail | **PASSED 18/0 — DEFECT** |
| M9 | real IOKit listener present, hold-only text removed | F2 passes via listener | PASS (18/0) |

M1–M7 and M9 behave correctly. **M8 exposed a real paper control.**

### Defect: the F2 assertion was satisfiable by incidental prose

The old form was:

```
has_listener=... grep 'AppleClamshell|IOPMCopyPowerSource|clamshell' <code>
has_decision=... grep 'hold-only|hold only|clamshell' "$REPO/docs/"
```

Both branches matched the bare word `clamshell`, and the docs branch scanned all of
`docs/`. `docs/RESEARCH.md` mentions "clamshell" incidentally in the **F1** background
section ("On Apple Silicon, clamshell sleep is firmware-level"), which is unrelated to
the F2 decision. So the assertion was satisfied by F1's prose: deleting the *entire*
in-code F2 hold-only rationale (KjolHelper/main.swift:138-148) still scored 18/18.
The F2 win-condition was therefore not enforcing anything about F2.

### Fix

The docs-only branch is removed; docs may explain the verdict but may no longer be the
sole evidence for it. The listener branch now requires a genuine IOKit API symbol
(`AppleClamshellState`, `IOPMCopyPowerSource`, `IONotificationPort`,
`IORegisterForSystemPower`) rather than the word "clamshell" in a comment, and the
hold-only branch requires the decision phrase in the helper/app source next to the hold
itself, where an editor about to remove it will actually read it. Re-verified: real
sources still 18/18; M8 now correctly FAILS 17/1; M9 still passes via the listener
branch, so the assertion remains satisfiable either way as PRIORITIES.md F2 intends.

Pass count is unchanged (18) — this iteration strengthened an existing assertion rather
than adding one.

### Sandbox note for later iterations
`/usr/bin/perl`, `/usr/bin/head` and `/usr/bin/tail` are DENIED by the profile. Use
`sed -i ''` / `awk` for mutation and line-limiting. Mutation copies go under
`kjol-overseer/build/`, never `/tmp` (also denied).

## Mutation verification of F0/F5/F6 (worker addition, completing the F1–F4 pass)

The prior iteration closed by naming F0/F5/F6 as un-mutated assertions and predicting
the F0 regex was loose "in the same way F2's was". Driven negative against a sandbox
copy of the repo (`kjol-overseer/build/mut`), never against the live tree.

| Mutation | Assertion | Result |
|---|---|---|
| inject `GeometryReader` into main.swift | F5 zero-GeometryReader | FAILS correctly |
| inject `withAnimation` token | F5 zero-animation | FAILS correctly |
| rename `assertSleepDisabledOff()` call site | F6 guard-called | FAILS correctly |
| add `scheduledTimer` to helper | F6c no-timer-in-helper | FAILS correctly |
| replace RESEARCH.md with `We adopt a cat.` | F0 discovery gate | **PASSED — DEFECT** |

### Defect: the F0 discovery gate was satisfiable by incidental prose
The gate was `grep -qiE 'discovery|unconsid|not consider|adopt'` over the whole file.
Any document containing the substring "adopt" satisfied it, so the F0 win condition
proved nothing about whether a discovery pass had actually been recorded. Same defect
class as the F2 assertion fixed earlier: prose matching instead of structure matching.

### Fix
Replaced with a structural check requiring all four of: a `## Discovery` heading, an
`Adopted` subsection, a `Rejected` subsection, and >=1 real citation (`https?://`).
Re-mutated: "We adopt a cat." now FAILS (head=0 adopted=0 rejected=0 cited=0); headings
without a citation FAIL (cited=0); Adopted-without-Rejected FAILS (rejected=0); the real
document passes. Pass count unchanged at 19 — this hardens an existing assertion rather
than adding one.

With this, every assertion in the checker (F1–F9) has now been mutation-proven.

### Sandbox pollution recurred (F7/F9 caught it live)
Editing the checker via the file tool caused the sandbox's `hermes-cwd-*.txt: Operation
not permitted` stderr line to be appended INTO the checker itself. F9 failed immediately
and correctly (pass=18 fail=1) — the pollution guard is not theoretical. Stripped with a
`grep -v` filter. Later iterations: after ANY write, re-run the checker; a lone F7/F8/F9
failure means stderr landed in a file, not that a feature regressed.

## P2 — RESOLVED/ADOPTED: `Timer.tolerance` for wakeup coalescing (2026-08-08)

Previously listed under "Pending (await discovery sub-agent citations)". Resolved this
iteration and implemented; promoted to win-condition **F10** in PRIORITIES.md.

**Verdict: ADOPT.**

**Finding.** Foundation's `Timer` exposes a `tolerance` property whose documented purpose is
exactly this use case: allowing the system to fire the timer later than its scheduled point so
the wakeup can be coalesced with other activity, reducing power consumption. Apple's own
guidance in that documentation is that a tolerance should be set on any timer where firing
precision is not required, and that the value should generally be at least 10% of the interval
for a meaningful energy benefit. Critically for a *repeating* timer, the documentation notes
that applying a tolerance does NOT cause cumulative drift: each subsequent fire is scheduled
relative to the timer's original start time, so tolerance shifts an individual fire within its
window but the long-run cadence is preserved.

Citation: Apple Developer Documentation — Foundation, `Timer.tolerance`
(https://developer.apple.com/documentation/foundation/timer/tolerance). Energy-efficiency
rationale for coalescing periodic work is covered in Apple's Energy Efficiency Guide for Mac
Apps ("Minimize Timer Use" / timer coalescing).

**Why this app is the ideal case.** Kjol is an LSUIElement menu-bar poller: its two repeating
timers exist precisely to keep running while the machine is otherwise idle, which is when a
forced strict-schedule wakeup is most expensive. Neither timer needs precision — one refreshes a
status snapshot, the other repaints a menu-bar glyph. There is no correctness dependency on
firing at an exact instant.

**Implemented (Kjol/main.swift).**
- `Host.startPolling(interval:)` — `t.tolerance = interval * 0.1`, expressed as a fraction so it
  tracks the 3.0s-visible / 15.0s-idle cadence automatically if that cadence is ever retuned.
- `AppDelegate.updatePolling()` idle icon timer — `t.tolerance = 1.5` (10% of its fixed 15.0s).

**Rejected alternative.** Switching to a `DispatchSourceTimer` with a leeway parameter would give
equivalent coalescing, but it would mean rewriting both timer sites and their invalidate paths,
putting the existing "exactly 2 repeating timers" and "timer invalidated in deinit" guarantees at
risk for no additional power benefit. `Timer.tolerance` is a two-line change achieving the same
coalescing, so the rewrite is not justified.

**Machine-checked by** two F10 assertions in `scripts/check-kjol-design.sh`, both
mutation-verified (removing either tolerance, or hardcoding the poll tolerance, flips the suite
to fail). Checker now 21/0.

**Still pending** (dispatched to a research sub-agent this iteration, verdicts to be folded in
when it returns): P1 hidden-panel body evaluation, P3 QoS / App Nap for an LSUIElement poller,
P4 pmset restoration when the helper dies, P5 IOPMAssertionCreateWithName vs spawning caffeinate.

## M11 — F4 assertion was a paper control (worker, verification strengthening)

**Claim.** The F4 win-condition ("per-core CPU sampler present") did not prove the
sampler exists in executable form.

**Evidence.** The assertion was
`grep -rchE 'host_processor_info|PROCESSOR_CPU_LOAD_INFO|processor_info\('` over
`Kjol/main.swift` + `KjolHelper/`. `CpuSampler` carries a large doc comment that
names all three tokens, so the count never drops to 0 no matter what the code does.
Mutation M11a renamed the single real call site
(`host_processor_info(mach_host_self(), ...)` -> `host_processor_infoX(...)`) and the
checker still reported **pass=21 fail=0**. F4 — the one feature PRIORITIES.md records as
the genuine implementation gap — was therefore machine-checked by prose only.

**Why it matters.** F4 is the feature most likely to regress, and the assertion guarding
it would have stayed green through its deletion. This is the paper-control class the loop
already found in F2 (M8) and F7, recurring in the feature the plan cares most about.

**Fix.** Two assertions added, both filtering comment lines (`grep -vE '^[[:space:]]*//'`)
before matching:
- `F4 sampler makes a REAL host_processor_info() call (non-comment)`
- `F4 sampler releases the kernel buffer (vm_deallocate, no per-tick leak)`

The second guards a distinct real defect rather than restating the first: the kernel
`vm_allocate`s a fresh buffer on **every** `host_processor_info` call and the caller owns
it, so a sampler on a repeating poll timer that omits `vm_deallocate` leaks on each tick —
which would violate the loop's bounded-allocation invariant while every existing
assertion stayed green. `CpuSampler.releasePrev()` already implements this correctly
(exactly one buffer retained between ticks, released in `deinit`).
Citation: `host_processor_info` buffer ownership —
https://developer.apple.com/documentation/kernel/1502854-host_processor_info ; the
vm_deallocate-the-previous-buffer idiom — https://stackoverflow.com/a/6795612

**Mutation-verified in both directions (not a paper control):**

| Mutation | Result |
|---|---|
| baseline | pass=23 fail=0 |
| M11a rename real `host_processor_info(` call | pass=22 fail=1 |
| M11b rename `vm_deallocate(` | pass=22 fail=1 |
| restored | pass=23 fail=0 |

Expected checker pass count: **23** (was 21).

**Incidental defect found and fixed.** Writing this iteration's checker edit injected a
literal sandbox stderr line (hermes-cwd temp-file "Operation not permitted") as line 208
of `check-kjol-design.sh` — the exact F9 defect class, produced by the editing tool
capturing sandbox stderr into file content. Removed with an anchored `sed -i ''` delete;
file 208 -> 207 lines, `bash -n` clean, F9 green. Confirms F9 guards a live, recurring
hazard rather than a hypothetical one.

## P4 — MEASURED EVIDENCE (worker inspection, awaiting sub-agent verdict)

**Status: evidence recorded, NOT yet a verdict.** The research sub-agent (role=leaf,
findings-only) covering P1/P3/P4/P5 was dispatched this iteration and has not returned.
No implementation change is made on P4 until it does — per AGENT_GOAL, Apple power APIs
are not to be guessed. What follows is code inspection of the CURRENT state only, so the
eventual verdict lands against measured facts rather than a remembered description.

**Claim.** `KjolHelper` mutates persistent system-wide state and has no restoration
path other than the explicit user-driven disable call. If the helper dies while always-on
is active, the machine is left permanently unable to sleep.

**Evidence (all line numbers `KjolHelper/main.swift`, verified this iteration):**

| Fact | Location | Detail |
|---|---|---|
| Four persistent pmset writes on enable | 149-152 | `sleep 0`, `displaysleep 10`, `hibernatemode 0`, `ttyskeepawake 1` |
| Restoration exists ONLY on the disable branch | 179-186 | `killCaffeinate()` + `disablesleep 0` + `reapplyMode(...)` |
| `reapplyMode` is the only writer of sleep defaults | 190-200 | `sleep 1`, `displaysleep 10`, `hibernatemode 3` |
| Intent IS already persisted to disk | 166 | `writeState("always_on", "1")` under `/var/db/kjol` |
| No startup reconciliation | 417-422 | `main` constructs the listener and resumes; `KjolHelper.init()` (24-27) calls only `setupStateDir()` |
| No client-death detection | 409-414 | `listener(_:shouldAcceptNewConnection:)` sets interface/object and resumes — no `invalidationHandler`, no `interruptionHandler` |
| Child process is not assertion-backed | 257-269 | `caffeinate -u -i -s` spawned as a `Process`; pid mirrored to `caffeinate.pid` (265) |

**Why it matters.** `pmset` settings are persistent system configuration, not
process-scoped. The three failure modes the current code does not cover:

1. **Helper crash / SIGKILL while always-on is active.** `sleep 0` + `hibernatemode 0`
   survive the process. Nothing ever restores them — the user's Mac silently stops
   sleeping, with no UI affordance pointing at Kjol as the cause. Note the state file
   at line 166 already records that always-on was active, so the information needed to
   reconcile is on disk and is simply never read at startup.
2. **App quits without calling `setAlwaysOn(false)`.** The helper is a LaunchDaemon and
   keeps running, holding the hold, with no client. There is no `invalidationHandler` at
   409-414 to notice the client vanished.
3. **Orphaned `caffeinate`.** `killCaffeinate` (271-282) recovers via the pid file and a
   `pkill -f "caffeinate -u -i -s"` fallback, so this one is *partially* covered — but
   only when the disable path actually runs.

Failure mode 1 is the material one: it is user-visible, persistent, and self-inflicted.

**Note this is orthogonal to F6.** `assertSleepDisabledOff()` (233-253) hardens the
*enable* path against a stray `SleepDisabled=1`. It does not restore anything, and it
does not run on any death path. F6 being green is not evidence P4 is covered.

**Candidate directions to put to the sub-agent's verdict (NOT decided here):** startup
reconciliation reading `always_on` before `listener.resume()`; an XPC
`invalidationHandler` reverting on client death; and P5's `IOPMAssertionCreateWithName`,
whose relevance is precisely that an assertion is released by the kernel when its owning
process dies — which is the crash-safety property the pmset-write path structurally
cannot have. The open question the sub-agent must settle is whether an assertion is
*sufficient* for lid-closed hold on Apple Silicon, where clamshell sleep is firmware-level;
if it is not, the pmset writes must stay and the fix has to be reconciliation-based rather
than assertion-based.
