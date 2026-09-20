# SRM Autoconnect — Windows Port Roadmap

This document is the building roadmap for porting the existing macOS/iOS menu-bar app to a Windows system-tray application. The Windows version lives in the `windows/` directory inside this same repository and replicates the exact same workflow: detect SRMIST Wi-Fi, check internet reachability, auto-submit portal credentials, retry on failure, and notify the user.

---

## Architecture Overview

| Concern | macOS (current) | Windows (target) |
|---|---|---|
| Language | Swift | C# (.NET 8+) |
| UI Framework | SwiftUI popover from NSStatusItem | WPF system-tray app (Hardcodet.NotifyIcon.Wpf) |
| Headless browser | WKWebView (offscreen) | WebView2 (Microsoft.Web.WebView2) |
| Wi-Fi detection | CoreWLAN (`CWWiFiClient`) | Native WiFi API via `ManagedNativeWifi` NuGet |
| Credential storage | macOS Keychain (generic-password) | Windows Credential Manager (native `advapi32` interop) |
| Notifications | `UNUserNotificationCenter` + `NSSound` | Windows Toast Notifications (`Microsoft.Toolkit.Uwp.Notifications`) |
| Network path monitor | `NWPathMonitor` | `NetworkChange` events + `NetworkInterface` polling |
| Logging | `~/Library/Logs/SRMAutoconnect.log` | `%LOCALAPPDATA%\SRMAutoconnect\SRMAutoconnect.log` |
| Open at login | `SMAppService.mainApp` | Registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |
| Build system | `build.sh` + `swiftc` | `dotnet build` / `dotnet publish` (MSBuild) |
| Installer (optional) | `ditto` to `~/Applications` | Single-file publish or Inno Setup / MSIX |

---

## Directory Layout (inside this repo)

```
Srm-AutoConnect/
├── App/                          # Existing macOS source (unchanged)
├── Assets/
├── build.sh
├── Info.plist
├── README.md
├── Roadmap.md                    # ← this file
│
└── windows/                      # NEW — everything for the Windows port
    ├── SRMAutoconnect.sln        # Visual Studio solution
    ├── SRMAutoconnect/           # Main WPF project
    │   ├── SRMAutoconnect.csproj
    │   ├── App.xaml / App.xaml.cs
    │   ├── Core/
    │   │   ├── AutoConnectManager.cs
    │   │   ├── NetworkMonitor.cs
    │   │   ├── CredentialStore.cs      # Keychain → Credential Manager
    │   │   ├── Logger.cs
    │   │   └── NotificationService.cs
    │   ├── Views/
    │   │   ├── TrayIcon.xaml           # System-tray icon + context menu
    │   │   ├── MainPopup.xaml          # Popup window (Dashboard/Logs/Settings tabs)
    │   │   ├── DashboardView.xaml
    │   │   ├── LogsView.xaml
    │   │   └── SettingsView.xaml
    │   ├── Helpers/
    │   │   └── Theme.cs
    │   ├── Assets/
    │   │   └── tray-icons/             # .ico files for each state
    │   └── build.ps1                   # One-command build + publish script
    └── SRMAutoconnect.Tests/           # Unit / integration tests
        ├── SRMAutoconnect.Tests.csproj
        ├── InjectionHarnessTests.cs
        └── Fixtures/
            ├── portal-jsbutton.html
            └── srm-portal.html
```

---

## Phases

### Phase 0 — Project scaffolding
**Goal:** Buildable empty WPF app that runs in the system tray and opens a blank popup.

- [x] Create `windows/SRMAutoconnect.sln` and `SRMAutoconnect.csproj` targeting `net8.0-windows`.
- [x] Add required Windows dependencies:
  - `Hardcodet.NotifyIcon.Wpf` (system-tray icon)
  - `Microsoft.Web.WebView2` (offscreen browser)
  - `ManagedNativeWifi` (Wi-Fi SSID detection)
  - `Microsoft.Toolkit.Uwp.Notifications` (toast notifications)
  - Native Windows Credential Manager interop (implemented in Phase 3; no compatibility-warning NuGet package)
- [x] Wire `App.xaml` to suppress the main window (`ShutdownMode="OnExplicitShutdown"`).
- [x] Add a `TaskbarIcon` from Hardcodet with a placeholder Wi-Fi icon.
- [x] Left-click opens a small `MainPopup` window (300 × 400, borderless, topmost, positioned above the tray icon — same feel as the macOS popover).
- [x] Right-click shows a context menu with **Open**, **Force Connect**, **Reveal Log File**, and **Quit**.
- [x] Verify the app starts, shows the tray icon, and shuts down cleanly.

**Deliverable:** A running skeleton. No business logic yet.

**Status:** Completed. `dotnet build windows/SRMAutoconnect.sln` succeeds, and a start/stop smoke test confirmed the tray app launches without exiting immediately.

---

### Phase 1 — Theme and UI shells
**Goal:** The three tabs (Dashboard, Logs, Settings) rendered in the same black-and-green terminal aesthetic.

- [x] Port `Theme.swift` → `Theme.cs` (static brushes, monospace font helper, terminal-panel style).
- [x] Build `MainPopup.xaml` with a tab bar at the bottom (Dashboard / Logs / Settings) matching `MainMenuView.swift`.
- [x] Build `DashboardView.xaml` with:
  - Header ("SRM AUTOCONNECT") + connection indicator dot.
  - Success / Failed metric cards.
  - LAST CONNECTED, CURRENT NETWORK, NEXT ATTEMPT rows.
  - CONNECTING spinner.
  - Result banner (CONNECTED / ALREADY ONLINE / LOGIN FAILED with reason).
  - FORCE CONNECT button pinned below the scroll area.
- [x] Build `LogsView.xaml` with scrollable list, copy and clear buttons, flash feedback.
- [x] Build `SettingsView.xaml` with SRM ID field, password field, Open at Login toggle, Save / Forget / Quit buttons, status messages.
- [x] Add scanline overlay (`DrawingVisual` or `Canvas` with horizontal lines at 3 px pitch).
- [x] Add tray-icon assets for each state: connected, connecting, failed, not-on-SRMIST.

**Deliverable:** All UI laid out and styled. Bound to placeholder ViewModels with dummy data.

**Status:** Completed. The Windows popup now has themed Dashboard, Logs, and Settings shells, placeholder tab interactions, scanline overlay, and tray icon assets. `dotnet build windows/SRMAutoconnect.sln` succeeds, and a start/stop smoke test confirms the app launches.

---

### Phase 2 — Logger
**Goal:** Rotating file logger + in-app log list, identical behaviour to `Logger.swift`.

- [x] Log file at `%LOCALAPPDATA%\SRMAutoconnect\SRMAutoconnect.log`.
- [x] Rotate at ~1 MB, keep one `.log.1` backup.
- [x] Thread-safe file writes on a background queue.
- [x] `ObservableCollection<LogEntry>` capped at 300 entries, newest first.
- [x] Consecutive-duplicate collapsing ("×N").
- [x] `log()` = user-facing (UI + file), `debug()` = file-only (unless debug flag).
- [x] Wire into `LogsView`.

**Deliverable:** Logs show in the UI and persist to disk.

**Status:** Completed. `Core/Logger.cs` writes to `%LOCALAPPDATA%\SRMAutoconnect\SRMAutoconnect.log`, rotates at 1 MB, updates the Logs tab through an observable collection, and supports copy/clear actions. Build, startup smoke test, and log-file verification passed.

---

### Phase 3 — Credential store
**Goal:** Save / read / delete SRM credentials securely using the Windows Credential Manager.

- [x] Target: `Generic Credential` entries under `SRMAutoconnect/username` and `SRMAutoconnect/password`.
- [x] `Save(data, target)`, `Read(target) → byte[]?`, `Delete(target)` — all throw on real failures, return null only for "never saved".
- [x] Verify-after-write (read back and compare), exactly as `KeychainHelper.swift` does.
- [x] Wire into `SettingsView` (save, load on appear, forget).
- [x] Trim whitespace on the SRM ID, blank password = "keep stored", etc.

**Deliverable:** Credentials round-trip through the Windows Credential Manager.

**Status:** Completed. `Core/CredentialStore.cs` uses native Windows Credential Manager APIs, `SettingsView` now loads/saves/forgets credentials with read-back verification, and the old incompatible `CredentialManagement` package was removed. Build, credential round-trip self-test, startup smoke test, and lint check passed.

---

### Phase 4 — Network monitor
**Goal:** Detect the SRMIST SSID, track connectivity, and trigger login attempts — mirroring `NetworkMonitor.swift`.

- [ ] Poll the current SSID every 5 seconds via `ManagedNativeWifi` (or `Wlan` API).
  - Same loose matching: `ssid.ToUpper().Contains("SRMIST")`.
  - Same empty-read debounce (3 consecutive nil reads before committing "no network").
- [ ] `NetworkChange.NetworkAvailabilityChanged` + `NetworkChange.NetworkAddressChanged` as the Windows equivalent of `NWPathMonitor`.
- [ ] Track `IsConnectedToSRM`, `CurrentSSID`, `IsReadyForAutomaticLogin`.
- [ ] On SRMIST join → clear throttle, probe reachability.
- [ ] On SRMIST leave → cancel in-progress login, discard retries.
- [ ] System resume from sleep → cancel stale retry, settle 5 s, recheck (use `SystemEvents.PowerModeChanged`).
- [ ] Reachability throttle: 60 s while online, 10 s while offline.
- [ ] Double-probe offline confirmation (one offline reading → wait 3 s → confirm).

**Deliverable:** The tray icon reflects the real network state and `checkInternetIfNeeded()` fires correctly.

---

### Phase 5 — Reachability probes
**Goal:** The same canary-quorum check used by the macOS app.

- [ ] Canaries (unchanged):
  - `https://example.com` → contains "Example Domain"
  - `https://cloudflare.com/cdn-cgi/trace` → contains "fl="
  - `https://www.mozilla.org/robots.txt` → contains "user-agent" (case-insensitive)
- [ ] Quorum = 2/3.
- [ ] Apple captive-portal probe (`http://captive.apple.com/hotspot-detect.html`) to distinguish portal-intercept from dead network.
  - On Windows, optionally also / instead use Microsoft's `http://www.msftconnecttest.com/connecttest.txt` (expects "Microsoft Connect Test").
- [ ] Ephemeral `HttpClient` — no cache, no cookies, 6 s request timeout, 8 s resource timeout.
- [ ] Return `Reachability { Online, CaptivePortal, Detail }`.

**Deliverable:** `ProbeReachability()` returns the same verdicts as the macOS version.

---

### Phase 6 — AutoConnect manager (core logic)
**Goal:** The heart of the app — offscreen WebView2 portal login, matching `AutoConnectManager.swift` exactly.

- [ ] **Attempt lifecycle:**
  - Token-based invalidation (incrementing `currentAttempt`).
  - `isConnecting` flag, `attemptPhase` enum (Idle / Preflight / LoadingPortal / WaitingForLoginForm / Verifying).
  - Phase-specific watchdogs: portal navigation 18 s, login-form discovery 25 s, hard watchdog 120 s.
- [ ] **Preflight:**
  - If reachability says online → `AlreadyOnline`, done.
  - Else → load portal.
- [ ] **Portal navigation:**
  - Load `https://iac.srmist.edu.in/Connect/PortalMain` in the offscreen WebView2.
  - Only trust HTTPS on `iac.srmist.edu.in` (default port).
  - Handle navigation errors, TLS failures, redirects outside the trusted host.
- [ ] **Credential injection (JavaScript):**
  - Port the exact same JS blob: find `input[type="password"]`, find sibling text/email/tel input, set values via native property descriptor + `input`/`change` events.
  - Prefer `oAuthentication.submitActiveForm()`, fall back to visible submit controls, then `form.requestSubmit()`.
  - Report outcome back to C# via `window.chrome.webview.postMessage(...)` (WebView2 equivalent of `window.webkit.messageHandlers.srm.postMessage`).
- [ ] **Verification:**
  - After "submitted" → wait 3 s → poll reachability up to 5 times, 3 s apart.
- [ ] **Retry ladder:**
  - Network-not-ready: 1 s, 2 s, 3 s.
  - Normal retries: 3 s, 8 s, 20 s, 45 s (+ jitter).
  - Give-up cooldowns: 1 min, 3 min, 5 min, 10 min.
  - Missing-credentials backoff: 5 min.
- [ ] **Force Connect:** clears backoff, resets retry chain, works even off SRMIST.
- [ ] **Cancellation:** leaving SRMIST, readiness loss, system wake all cancel correctly.
- [ ] **`credentialsChanged()`:** clear backoff, retry immediately if on SRMIST.

**Deliverable:** The full login-and-retry engine, working end-to-end with WebView2.

---

### Phase 7 — Notifications
**Goal:** Toast notification + sound on successful login.

- [ ] Show a Windows toast: title "Connected to SRM Wi-Fi", body "You're all set."
- [ ] Play a system sound (e.g. `SystemSounds.Asterisk` or a bundled `.wav`).
- [ ] Show toast even when the app window is focused (Windows toasts do this by default).

**Deliverable:** User sees and hears a successful connection.

---

### Phase 8 — Open at Login
**Goal:** Toggle to start the app on Windows login.

- [ ] Write / remove `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\SRMAutoconnect` pointing to the exe path.
- [ ] On `SettingsView` appear, read the registry to sync the toggle state.
- [ ] Log success / failure.

**Deliverable:** The app launches on boot when enabled.

---

### Phase 9 — Tray icon state machine
**Goal:** The tray icon dynamically reflects the app state, like the macOS menu-bar icon.

| State | Icon | Tooltip |
|---|---|---|
| On SRMIST, idle | Wi-Fi icon | "SRM Autoconnect — on SRMIST" |
| Logging in | Rotating arrows | "SRM Autoconnect — logging in" |
| Login failed | Wi-Fi with exclamation | "SRM Autoconnect — login failed" |
| Not on SRMIST | Wi-Fi with slash | "SRM Autoconnect — not on SRMIST" |

- [ ] Create `.ico` files (16×16, 32×32, 48×48 sizes embedded) for each state.
- [ ] Bind the `TaskbarIcon.IconSource` to a computed property driven by `IsConnectedToSRM`, `IsConnecting`, `LastResult`.

**Deliverable:** The tray icon is a live status indicator.

---

### Phase 10 — Build script and packaging
**Goal:** One-command build, identical to `./build.sh` on macOS.

- [ ] `windows/build.ps1`:
  - Stop any running instance (`Stop-Process`).
  - `dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true`.
  - Copy output to a well-known install directory (e.g. `%LOCALAPPDATA%\Programs\SRMAutoconnect\`).
  - Launch the installed copy.
- [ ] Optionally produce an Inno Setup installer or MSIX package for distribution.

**Deliverable:** `.\build.ps1` builds and launches in one step.

---

### Phase 11 — Tests
**Goal:** Port the existing test fixtures and add Windows-specific tests.

- [ ] Create `SRMAutoconnect.Tests` project (xUnit or NUnit).
- [ ] **Injection harness tests:** Load `fixtures/srm-portal.html` and `fixtures/portal-jsbutton.html` in WebView2, run the injection JS, assert that `postMessage` reports "submitted".
- [ ] **Credential store tests:** Save → read → verify → delete round-trip.
- [ ] **Reachability tests:** Mock `HttpClient` responses, assert quorum logic.
- [ ] **Retry ladder tests:** Simulate failure sequences, assert delays and generation invalidation.
- [ ] **Network monitor tests:** Simulate SSID changes, assert `IsConnectedToSRM` transitions and cancellation.

**Deliverable:** CI-ready test suite.

---

### Phase 12 — Documentation and README update
**Goal:** Update the repo README and add Windows-specific docs.

- [ ] Add a `windows/README.md` covering:
  - Requirements (Windows 10 1809+, .NET 8 runtime or self-contained, WebView2 runtime).
  - Build and run instructions.
  - First-use checklist (build → allow notifications → save credentials → optionally enable Open at Login).
  - Log file location.
- [ ] Update the root `README.md` to mention the Windows version and link to `windows/README.md`.

**Deliverable:** Both platforms documented in one repo.

---

## Key Porting Decisions

### Why C# / WPF?
- Native Windows citizen — system tray, toast notifications, registry, Credential Manager all have first-class .NET support.
- WebView2 (Edge-based) is the official Microsoft answer to WKWebView and has a mature C# SDK.
- Single-file publish produces a portable exe, similar to the macOS `.app` bundle.
- WPF supports the same kind of borderless, themed, popover-style window the macOS SwiftUI popover provides.

### Why not Electron / Tauri / Python?
- Electron ships a full Chromium — overkill for one offscreen page.
- Tauri could work but adds a Rust toolchain dependency.
- Python (with `pywebview`) lacks native tray-icon UX and credential-manager integration without significant wrapper code.
- C# keeps the Windows port idiomatic and dependency-light, just as Swift keeps the macOS version idiomatic.

### WebView2 vs CefSharp
- WebView2 is pre-installed on Windows 10 20H2+ and all Windows 11 machines (Edge is the host). No extra runtime to bundle.
- CefSharp ships ~200 MB of Chromium. Unnecessary weight for one hidden page.

### Credential Manager vs DPAPI raw
- Windows Credential Manager is the direct analogue of macOS Keychain — it is what Windows itself uses for saved passwords.
- DPAPI encrypts blobs but requires the app to manage storage. Credential Manager handles both.

---

## Estimated Effort

| Phase | Effort |
|---|---|
| 0 — Scaffolding | 1 day |
| 1 — Theme & UI | 2–3 days |
| 2 — Logger | 0.5 day |
| 3 — Credential store | 0.5 day |
| 4 — Network monitor | 2 days |
| 5 — Reachability probes | 0.5 day |
| 6 — AutoConnect manager | 3–4 days |
| 7 — Notifications | 0.5 day |
| 8 — Open at Login | 0.5 day |
| 9 — Tray icon states | 0.5 day |
| 10 — Build script | 0.5 day |
| 11 — Tests | 2 days |
| 12 — Docs | 0.5 day |
| **Total** | **~14–16 days** |

---

## Build Order Summary

```
Phase 0   Scaffolding (empty tray app)
  │
Phase 1   Theme + UI shells (all three tabs, styled, dummy data)
  │
  ├── Phase 2   Logger
  ├── Phase 3   Credential store
  │
Phase 4   Network monitor
  │
Phase 5   Reachability probes
  │
Phase 6   AutoConnect manager ← the big one
  │
  ├── Phase 7   Notifications
  ├── Phase 8   Open at Login
  ├── Phase 9   Tray icon state machine
  │
Phase 10  Build script + packaging
  │
Phase 11  Tests
  │
Phase 12  Docs
```

Phases at the same indent level (2–3, 7–8–9) are independent and can be done in parallel.
