# macOS Connection Latency Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task by task. Steps use checkbox syntax for tracking. Follow the repository's serious-change review policy after implementation and relevant checks.

**Goal:** Make the Mac connect reliably on its first portal attempt and remove unnecessary waiting before usable internet is confirmed.

**Architecture:** Preserve the existing NetworkMonitor → AutoConnectManager → trusted HTTPS portal flow. Make SRM authentication readiness explicit, isolate connectivity aggregation for deterministic tests, and keep attempt tokens and network generations authoritative across callbacks.

**Tech Stack:** Swift, AppKit, CoreWLAN, Network.framework, WebKit, URLSession; local Swift/WebKit test harnesses.

**Spec:** The design and scope below, based on the user's request to investigate slow connection and plan a proper fix for macOS only.

## Evidence and diagnosis

The local diagnostic log on 2026-10-06 contains one complete slow join. Times below are relative to the `Wi-Fi: none → SRMIST` event. They measure detection to *verified* internet; they do not measure the gateway's exact opening time.

| Elapsed | Event | Interpretation |
| --- | --- | --- |
| 0.000s | SRMIST detected | Start of measured join |
| 6.138s | First offline probe completes | External requests fail around their request timeout |
| 15.285s | Second offline probe completes | Two probe batches plus the 3s confirmation delay |
| 15.351s | Portal navigation starts | Confirmed-outage result is reused; no duplicate preflight here |
| 17.088s | Portal loaded | Initial portal navigation takes only 1.737s |
| 17.603s | Script reports submit via `A#UserCheck_Login_Button` | Authentication handler was unavailable or threw before fallback |
| 63.046s | First attempt fails | Five failed verification batches and 3s gaps consume 45.443s |
| 73.435s | Retry loads portal | Retry wait plus a fresh external preflight |
| 74.094s | Submit via `oAuthentication.submitActiveForm` | Retry takes the portal's intended authentication path |
| 77.715s | Internet verified | Handler invocation to verification takes 3.621s |

**Primary defect reproduced locally:** In `App/AutoConnectManager.swift:619-669`, finding both fields ends the readiness timer. If the SRM authentication function is not available, the script clicks the anchor and reports `submitted` anyway. A temporary local fixture rendered the fields/anchor immediately and initialized the handler after 1.5s. The extracted production script clicked early, reported submission, and never authenticated. This reproduces the failure mechanism; the production log alone cannot prove that this exact initialization race caused its first failed attempt. The handler could also have thrown, which the current code silently catches.

**Existing test blind spot:** `tests/InjectionHarness.swift:49-60` evaluates an IIFE without returning its JSON. WebKit returns nil, and the conditional assertions are skipped while `pass` remains true. In a temporary corrected harness, both existing fixtures executed six assertions and passed; the delayed-handler fixture failed the submit-path and actual-submission assertions as expected. No production source or committed tests were changed during diagnosis.

**Secondary latency:** Reachability currently waits for all three ordinary canaries and Apple's diagnostic request (`AutoConnectManager.swift:751-786`). Two successful canaries already prove online, but a slow third request can hold up completion. Verification starts after a fixed 3s delay and each failed batch is followed by another 3s delay (`698-735`). A previously online connection that expires without a path/SSID change can wait approximately 60–75s before the next probe starts because the 60s throttle is driven by a 15s timer (`NetworkMonitor.swift:66,153,212`). These are separate from the first-attempt authentication bug.

**Not established:** Current portal JS initialization details, its actual login response, or current server performance. A read-only fetch of the live portal failed to connect during diagnosis. The 5s wake fallback and App Nap protection already exist; neither explains the recorded 77.7s join, which contains no wake event or long scheduler gap. Do not reimplement existing fixes based on historical comments.

## Design and scope

Implement the readiness fix first, with a failing regression test. For the recognized SRM password form/anchor, wait for the callable authentication handler within the existing 25s form watchdog; invoke it once. Keep the generic button path working for the existing generic fixture. If the SRM handler never appears or throws, report a specific form/submission failure; do not fall through to a native submission that bypasses the portal's authentication processing.

Then make online verification decisive and prompt. Keep the existing 2-of-3 ordinary-canary rule and 6s request/8s resource budgets initially. Complete online as soon as the second valid response arrives, cancel unnecessary tasks, and start post-submit verification immediately. Retain bounded retry spacing after a negative result. Apple remains diagnostic evidence only.

Treat detection speed as a separate policy: a confirmed portal interception plus a negative ordinary-canary result can skip the second outage confirmation, while an ambiguous outage still needs both probes. Reduce healthy-state detection throttle to 15s using the existing timer. Keep wake's 5s fallback, but allow an immediate check when the observed network is already ready. Measure the request-volume cost of the shorter healthy-state interval before release.

Healthy-campus targets for validation, not promises: first join verified within 25s under the observed roughly 2s portal load; no retry caused by delayed handler initialization; successful verification completes immediately after the second valid canary response. Record actual distributions before claiming an improvement.

### Global constraints

- macOS only; no changes under `windows/` or Windows build scripts.
- Keep macOS 13.0 deployment support and avoid new third-party dependencies.
- Credentials are read from Keychain and submitted only to the existing trusted HTTPS SRM host with normal TLS validation.
- Preserve quorum evidence; an Apple success page alone never proves internet access.
- Preserve single active attempt, attempt-token invalidation, network-generation checks, and bounded watchdogs.
- Preserve long cooldowns for genuine persistent failures; do not shorten all timeouts or remove backoff to mask failed authentication.
- Diagnostics exclude credentials, portal response bodies, and URL queries/fragments.

### Review focus

1. Handler absent or delayed: wait safely, submit once, and give a specific bounded failure.
2. Handler throws: do not convert a failed SRM submission into a fallback click and false success.
3. Two valid canaries plus a stalled request: complete once and ignore cancellation/late callbacks.
4. Sleep, roam, or path loss during verification: old results cannot finish or retry a new attempt.
5. Internet already available or reachable through a VPN: preserve normal quorum behavior and avoid repeated portal submissions.

## Task 1: Repair injection assertions and wait for SRM authentication readiness

**Files:** Modify `tests/InjectionHarness.swift`, `tests/run-injection-test.sh`, `App/AutoConnectManager.swift`; create `tests/fixtures/srm-portal-delayed-handler.html`, `tests/fixtures/srm-portal-missing-handler.html`, and `tests/fixtures/srm-portal-throwing-handler.html`.

**Interfaces:** Keep the existing script-message envelope `{attempt, stage, detail}`. Add stage `submiterror` for handler invocation errors and `handlernotready` for a missing handler at the readiness deadline; handle both in `userContentController(_:didReceive:)` with specific failure reasons. No public login-entry signature changes.

- [x] Return `JSON.stringify(...)` from the inspection IIFE. Fail on evaluation error, missing/malformed JSON, injection error, or a harness deadline; never let skipped assertions produce PASS. Record fixture expectations so negative fixtures can assert the correct failure outcome. Give the harness 35s overall for the missing-handler test.
- [x] Add the delayed fixture: render SRM fields/anchor immediately, bind the authentication handler after 1.5s, record early clicks and handler-call count. Assert no early click, exactly one handler invocation, actual submission, and exactly one submitted report. Run `bash tests/run-injection-test.sh`; this new case must fail against the current script while the existing two fixtures pass with assertions executed.
- [x] Change `injectLogin(_:)` in the recognized SRM form/anchor path to wait for `oAuthentication.submitActiveForm` before stopping discovery and submitting. Reuse the 25s watchdog; make JS's readiness deadline occur before it so the failure stage can be received. Reserve generic clicking for the generic variant; do not silently swallow a thrown SRM handler and fall through.
- [x] Extend failure fixtures: missing handler produces a bounded `handlernotready` result without any fallback submit; throwing handler produces `submiterror` with no second dispatch. Error detail must use a fixed safe diagnostic, not raw page exception text. Verify the generic fixture remains green and report details exclude fake field values.
- [x] Re-run the injection harness and inspect the Mac-only diff. Commit this independently reviewable readiness fix when execution is authorized.

## Task 2: Make reachability decisive and begin verification immediately

**Files:** Create `App/ReachabilityProbe.swift`, `tests/ReachabilityHarness.swift`, `tests/run-reachability-test.sh`; modify `App/AutoConnectManager.swift`.

**Interfaces:** `ReachabilityProbe.Result` contains the existing `online: Bool`, `captivePortal: Bool`, and `detail: String`. `ReachabilityProbe.init(session: URLSession)` accepts an injected session for URLProtocol fixtures. `ReachabilityProbe.run(completion: @escaping (Result) -> Void)` owns one batch of request tasks and delivers exactly one completion on main. Preserve `AutoConnectManager.Reachability` as a typealias to that result and preserve its existing `probeReachability(quiet:completion:)` wrapper for callers.

- [x] Write deterministic URLProtocol tests: two valid ordinary responses plus a stalled third and stalled Apple request must complete online before either stall ends; one success plus Apple success must not complete online; late/cancelled callbacks must not deliver a second completion; invalid status or expected-body mismatch must not count as success.
- [x] Run `bash tests/run-reachability-test.sh` and confirm failure before implementing the aggregator.
- [x] Move existing canaries/session policy into the probe component. Serialize aggregation on one queue, decide online at quorum, and cancel remaining tasks. For offline decisions, wait until quorum is impossible and Apple's diagnostic result is known, or the existing batch budget expires; cancellation is not new negative evidence. Keep the case-insensitive body checks and cache/cookie policy.
- [x] In the submitted-message path, call `verify(_:remaining:)` immediately instead of starting with `after(3, ...)`. Keep three-second spacing after an actually negative verification batch and the existing attempt guards. Test immediate first check, retained negative-result retry spacing, and invalidated-token callbacks with injected/local fixtures.
- [x] Run both test scripts and compile the Mac sources. Do not change timeout budgets until measured results justify it.

## Task 3: Reduce detection waits while preserving outage confidence

**Files:** Modify `App/NetworkMonitor.swift`; create `App/ConnectionDetectionPolicy.swift`, `tests/ConnectionDetectionHarness.swift`, `tests/run-connection-detection-test.sh`.

**Interfaces:** Use a pure policy to expose timing/confirmation decisions: `ConnectionDetectionPolicy.minimumProbeInterval(lastProbeWasOnline: Bool) -> TimeInterval` returns 15 for online and 10 for offline; `ConnectionDetectionPolicy.shouldLogin(after state: AutoConnectManager.Reachability, consecutiveOfflineProbes: Int) -> Bool` requires `!state.online` and either explicit captive interception or at least two consecutive negative probes. Monitor retains its generation/readiness guards and existing trigger entry points.

- [x] Add policy tests: online responses never trigger login, explicit captive interception can trigger on the first negative batch, ambiguous outage needs two negatives, and online observations reset confirmation history. Run the policy harness to confirm failure before implementing it.
- [x] Integrate the policy without resetting backoff on timer/path detail noise. Keep pending offline-confirmation work coalesced and scoped to the current generation.
- [x] Add monitor integration cases for stale results after leaving SRMIST, path loss/recovery while a probe is active, online via another interface, duplicate wake events, and a warm path at wake. Warm readiness should start a check immediately; retain one 5s fallback check for a path that is not ready, without launching overlapping batches.
- [x] Run all three harness scripts. Measure healthy-state polling volume: 15s polling is approximately 720 ordinary-canary requests/hour plus Apple diagnostics before early cancellation, versus the previous nominal 180 plus diagnostics. Document this battery/data tradeoff; if unacceptable, defer this interval change rather than hiding it behind a speculative optimization.

## Task 4: Record phase timings and validate the deployed Mac behavior

**Files:** Modify `App/AutoConnectManager.swift`, `App/NetworkMonitor.swift`, and the Mac sections of `README.md`.

**Interfaces:** Keep logging through `Logger.shared.debug`. Include attempt/network generation, trigger reason, elapsed monotonic phase duration, canary host/status/error code/duration, and chosen submit path. Label handler dispatch separately from verified internet; dispatched credentials do not establish acceptance.

- [x] Instrument detection, preflight, navigation, handler readiness, handler invocation, verification, and retry wait. Test formatting with fake credentials and query-bearing URLs to ensure sensitive values never enter output.
- [x] Compile without running the install/relaunch script: `swiftc -O -module-cache-path /private/tmp/srm-mac-module-cache -target "$(uname -m)-apple-macosx13.0" App/*.swift -o /private/tmp/srm-mac-validation`. This avoids replacing or stopping the active app during checks.
- [x] Run the three focused harness scripts and inspect `git diff --check` plus the final diff for unintended Windows/source changes. The WebKit tests need a normal local macOS GUI session; sandboxed WebKit can stall, which must be reported as an environment limitation rather than PASS.
- [x] Review the completed production diff with `senior_reviewer`: authentication dispatch, asynchronous aggregation, network changes, watchdog boundaries, and missing regressions. Fix valid findings and re-run affected checks.
- [ ] On the campus network, measure at least five fresh joins, five wake recoveries, and one real same-SSID session-expiry case. Include delayed-handler, wrong/missing credentials, unavailable portal, transient SSID nil, and VPN cases. Separate time until usable internet from time until notification. Do not disconnect/reconnect the user's active connection or submit experimental live logins without authorization for that validation.
- [ ] Compare phase timing against the recorded 77.715s baseline. Release only after the first-attempt race is absent and quorum/cancellation behavior remains correct. Update README with verified behavior and any unperformed campus checks.

## Alternatives considered

- **Only shorten retries/timeouts:** May trim the 45s failed verification loop but leaves the false submission and can create extra login traffic. Reject as the primary fix.
- **Replace WebKit with direct portal HTTP login:** Requires reproducing the portal's authentication/session/encryption contract and creates unnecessary compatibility risk. Defer.
- **Readiness-first WebKit fix plus decisive probes:** Addresses the reproduced defect and preserves the portal's own authentication processing. Recommended.

## Current status

Local implementation is complete and reviewed. All four Mac harness scripts pass, including five WebKit fixtures, six connectivity scenarios, 23 detection assertions, and 14 verification assertions. The optimized Mac app compiles for the existing macOS 13.0 target. Senior review's stale pre-sleep probe finding was reproduced and fixed with per-probe identity; its regression passes. Windows files are unchanged. No app has been installed or relaunched. The two remaining checkboxes are live campus deployment checks and measured speed comparison; these remain pending authorization/access and cannot be claimed complete from local fixtures.
