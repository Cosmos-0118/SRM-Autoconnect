# Execution ledger — plan: 2026-10-06-mac-connection-latency.md

Pre-flight: Tasks 1 and 2 share script submission/verification. Preserve script envelope and attempt guards. Tasks 2 and 3 share Reachability result; preserve typealias. Task 4 logs all phases.

Ruling: Use the attached managed worktree and leave changes reviewable without committing yet; original checkout has an untracked user-visible plan. Campus experiments remain a deployment gate, not a prerequisite for building local fixes.

Task 1 RED: delayed-handler fixture failed real submission, handler count, and early-click assertions; existing fixtures passed. Implemented readiness wait and explicit handler errors.

Task 1 Ruling: JS polling counts were not a reliable 24s deadline under background timer throttling; use elapsed time instead and mirror the app activity token in its GUI harness. Native 25s watchdog remains authoritative.

Task 2 RED: deterministic harness against extracted original aggregator failed early quorum (two valid hosts waited for two 2s stalls). Added independent main-serialized batches and immediate first verification; budgets unchanged.

Task 3 RED: real monitor with original policy failed five assertions for immediate captive login, 15s expiry detection, recovery acceptance, and warm wake. Integrated policy, monotonic clock, and warm wake; retains ambiguous confirmation/cooldowns. Dependencies replace external system effects, not detection logic.

Task 1 GREEN: handler missing/throwing fixtures passed in a normal visible WebKit window. Ruling: GUI fixture tests use a visible local window because offscreen WebKit suspended JS timers even with process activity. Production keeps its invisible window plus native 25s watchdog.

Task 2 GREEN: five URLProtocol scenarios passed, including early quorum and 8s bounded offline completion. Task 3 GREEN: 21 policy/real-monitor assertions passed. One-hour simulated steady state measured 240 batches (720 ordinary + 240 diagnostic request starts), versus nominal 60 batches before.

Task 4 RED: verification tests exposed duplicate submit verification and URL userinfo retention. Added dispatch guard and userinfo redaction; new phase diagnostics use monotonic elapsed time. Ruling: explicit waiting/ready progress messages classify native 25s readiness failure even when offscreen WebKit suspends timers; they are not terminal submission reports.

Senior review P1: unresolved pre-sleep probe suppressed warm wake. Added failing real-monitor regression (immediate replacement and old callback must not release new gate), then replaced the global in-flight boolean with per-probe identity invalidated on each network epoch. Old batches remain bounded to 8s and cannot publish into a new epoch; their public canaries carry no credentials. No other blocking review issue reported.

Final local verification: all four harness scripts completed with exit 0; optimized swiftc build completed with exit 0; git diff --check clean. Senior P1 wake test RED→GREEN and full suite GREEN. No deferred code-review minors.

Task 1: local implementation complete — five real WebKit fixtures pass and inspection fails closed.
Task 2: local implementation complete — six deterministic scenarios pass, including pending cancellation and overlapping independent batches; actual verification dispatcher starts immediately and preserves retry spacing.
Task 3: local implementation complete — 23 real-monitor/policy assertions pass; stale probe identity cannot change replacement state.
Task 4: local diagnostics, documentation, build, and review complete — 14 extracted production verification/watchdog/redaction assertions pass. Installation, five physical joins, five wake recoveries, real expiry/VPN/portal checks, and campus timing comparison remain pending.

Ruling: Save the closely coupled implementation in one final reviewed commit, rather than intermediate commits that mix unverified probe/monitor interfaces. Keep the original checkout unchanged; retain the attached worktree for review and installation. No external release or live network disruption is authorized by local test execution.
