# SRM Autoconnect

SRM Autoconnect is a macOS menu-bar and Windows system-tray app for the SRMIST Wi-Fi captive portal. When it detects an SRMIST Wi-Fi network, it checks internet reachability, submits saved SRM credentials through the portal, and verifies internet access before reporting success.

The app has no Dock icon and no main window. Click the Wi-Fi icon in the menu bar to open its dashboard, logs, and settings.

## Windows setup and automatic connection

Requires Windows 10 or later and the Microsoft Edge WebView2 Runtime. Building requires the .NET 8 SDK; the installed Windows build includes the .NET runtime.

Run `build.cmd` (or `powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1`). It builds, installs to `%LOCALAPPDATA%\Programs\SRM Autoconnect`, enables **Open at Login** for that installed executable, and launches the tray app. Rebuilding updates the startup entry automatically. Use `-NoStartup` to skip changing startup registration or `-NoLaunch` to skip launching.

1. Open the tray icon, select **Settings**, and save your SRM ID and password once. Credentials stay in Windows Credential Manager.
2. Join the campus SRMIST Wi-Fi network and enable Windows' **Connect automatically** option for that Wi-Fi profile. Windows handles Wi-Fi association; this app handles captive-portal authentication.
3. On Windows versions that restrict Wi-Fi name access, enable **Location services** and access for desktop apps under **Settings > Privacy & security > Location**. The app must be able to read the SSID to trigger automatic login.

The app polls Wi-Fi every five seconds, checks an online session every 15 seconds, and rechecks after resume or network changes. A detected captive portal starts login immediately; ambiguous outages require a second check. Failed logins retry automatically with bounded backoff. Keep the app running in the tray; **Open at Login** can be disabled in Settings.

Windows uses an off-screen WebView2 browser. The login script selects the actual password field, waits for SRM's authentication handler, and calls its encryption/AJAX flow. Internet verification starts after submission even if the page does not navigate or show a success message. Reporting “Connected” still requires external reachability checks. Only one tray instance can run in a Windows session.

Windows logs are at `%LOCALAPPDATA%\SRMAutoconnect\SRMAutoconnect.log`; **Reveal Log File** opens their location.

Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-windows-regression.ps1` in a normal Windows desktop session. It exercises the production login manager in real WebView2 against local fixtures with fake credentials and controlled reachability. It covers separate username/password fields, generic forms, delayed/missing/throwing handlers, submission before navigation completes, rejected credentials, lack of internet after submission, and cancellation when network readiness is lost. It does not contact the campus portal or read saved credentials. Optional static checks: `py tests\check-windows-injection.py`.

Live joins, wake recovery, and session expiry on campus remain necessary to validate SRM's current portal and network behavior.

## What the app actually monitors

The Mac app recognizes Wi-Fi names containing `SRMIST` (case-insensitive), including campus variants. It reads the SSID with CoreWLAN every five seconds and listens for network-path changes. On wake it checks immediately if the current network is ready, with a five-second fallback while the interface recovers.

macOS requires Location Services permission before an app can read the current Wi-Fi name. Without that permission, SRM Autoconnect cannot automatically identify `SRMIST`.

While connected to `SRMIST`, the app probes external sites to decide whether the internet is available. It requires at least two of these three checks to pass:

- `https://example.com` contains `Example Domain`
- `https://cloudflare.com/cdn-cgi/trace` contains `fl=`
- `https://www.mozilla.org/robots.txt` contains `user-agent`

It also checks Apple's captive-portal page only to distinguish interception from a general outage. An Apple connectivity response alone never proves internet access. A probe completes as soon as two ordinary sites pass and cancels unused requests; request/resource budgets remain six/eight seconds.

An explicit interception with insufficient ordinary-host reachability can trigger login after one batch. Ambiguous outages still require two negative batches separated by three seconds. While online, connectivity checks are eligible every 15 seconds so a session expiring on the same Wi-Fi does not wait the previous 60-second throttle. This increases nominal steady-state request starts from roughly 240 to 960 per hour (720 ordinary requests plus 240 Apple diagnostics); early cancellation reduces unnecessary response waiting but does not guarantee fewer request starts.

## Login behavior

When the probes show that the internet is unavailable, the app:

1. Loads `https://iac.srmist.edu.in/Connect/PortalMain` in an off-screen `WKWebView`.
2. Refuses to inject credentials unless the loaded page remains HTTPS on `iac.srmist.edu.in` and uses the default HTTPS port.
3. Finds the password field and a text, email, or telephone username field in the same form.
4. Sets both fields and dispatches `input` and `change` events so portal pages with framework-managed form state receive the update.
5. For recognized SRM forms, waits for the portal's authentication handler before submitting through its encryption/AJAX flow. If the handler never becomes ready or throws, reports that specific failure instead of falling back to an early button click or native submit. Generic form variants can still use a real submit control.
6. Starts internet verification immediately after dispatch and repeats negative checks at three-second intervals. Dispatch is not considered success; ordinary-host quorum must confirm usable internet.

An attempt has phase-specific watchdogs: portal navigation is stopped after 18 seconds, the dynamically rendered login form is given 25 seconds, and a 120-second final watchdog covers unexpected WebKit/JavaScript stalls without interrupting the bounded reachability-verification loop. A failed attempt retries after approximately 3, 8, 20, and 45 seconds (with a small random delay). After those retries are exhausted, the next automatic attempt is delayed for 1, 3, 5, then 10 minutes. Leaving `SRMIST` cancels an in-progress login and discards pending retries.

**Force Connect** clears the current retry backoff and starts an attempt immediately. It may be used even when the current SSID is not `SRMIST`; the app still performs its normal internet check before loading the portal.

## Credentials, notifications, and logs

Enter your SRM ID and password on the **Settings** tab. They are stored as macOS generic-password Keychain items under the service `SRMAutoconnect`, with the accounts `username` and `password`, and are accessible only while the Mac is unlocked. The password is not loaded back into the settings UI. Saving verifies the write by reading it back, so a failure (denied keychain prompt, locked keychain, stale entry from a previous install) shows a red error with the fix instead of a false success — the same detail is written to the log.

At launch, the app requests permission for alerts and sounds. After a verified successful login, it shows a `Connected to SRM Wi-Fi` notification and plays the macOS `Glass` sound.

The dashboard persists its success count, failure count, and last successful connection time in `UserDefaults`. The **Logs** tab shows up to 300 recent user-facing events and can copy them to the clipboard. Diagnostic messages are written to:

```text
~/Library/Logs/SRMAutoconnect.log
```

The file rotates at roughly 1 MB, keeping one previous file as `SRMAutoconnect.log.1`. Diagnostics include attempt/network generation, trigger, monotonic phase durations, and canary host/status/error/timing. URL userinfo, queries, fragments, credentials, and response bodies are excluded from these diagnostics.

## Mac regression checks

Run `bash tests/run-injection-test.sh` in a normal Mac GUI session; it opens local fixture windows and uses fake credentials only. The fixtures cover generic submission, SRM submission, delayed/missing authentication initialization, and a throwing authentication handler. The harness fails if inspection returns no valid JSON or exceeds its deadline.

Run `bash tests/run-reachability-test.sh`, `bash tests/run-connection-detection-test.sh`, and `bash tests/run-verification-test.sh` for controlled URLSession responses, real monitor decisions with injected system observations, and production verification/token logic extracted into a local harness. No campus login or Keychain access occurs in these tests.

These checks establish local behavior. Post-change campus timings, five fresh joins, five wake recoveries, real session expiry, and physical VPN/portal failure cases remain deployment validation; the earlier 77.7-second join is a diagnostic baseline, not a measured post-change speed guarantee.

## Build and run

This repository is built directly with `swiftc`; it does not contain an Xcode project or Swift Package manifest.

Requirements:

- macOS 13 or later.
- Xcode Command Line Tools, providing `swiftc` and `codesign`.
- A code-signing identity named `SRM Autoconnect Dev` (machine-local — create it once per Mac with `./scripts/create-signing-cert.sh`; the Certificate Assistant GUI often fails with "The specified item could not be found in the keychain", which is a macOS bug the script works around).

Run:

```bash
./build.sh
```

The script stops an existing `SRM Autoconnect` process, rebuilds into `build/` (scratch space — safe to delete any time), compiles every `App/*.swift` file for the current Mac architecture with a macOS 13 deployment target, constructs the app bundle, copies `Info.plist` and `Assets/AppIcon.icns`, signs the bundle with `SRM Autoconnect Dev`, installs it to `~/Applications/`, and opens the installed copy.

The running application is:

```text
~/Applications/SRM Autoconnect.app
```

`build/` is disposable intermediate output. The installed copy in `~/Applications/` survives cache clears, `git clean -fdx`, and developer-junk cleaners, and it is also required for **Open at Login** (`SMAppService.mainApp`) to work reliably. To install system-wide instead, run `INSTALL_DIR=/Applications ./build.sh`.

The code-signing identity is a build requirement. It is separate from the SRM username and password that the app stores in the Keychain.

## First-use checklist

1. Build and open the app with `./build.sh`.
2. Allow notification permission if you want connection alerts.
3. On macOS 14 or later, allow Location Services permission so the app can identify the Wi-Fi name.
4. Open the menu-bar icon, go to **Settings**, and save your SRM ID and password.
5. Optionally enable **Open at Login** (available on macOS 13 or later).

If the portal login does not complete, use the **Logs** tab and check the log file above. A VPN or tunnel interface can prevent traffic from reaching a captive portal; the app reports this condition once per outage when it detects such an interface.

## Icon generation

`Assets/AppIcon.svg` is the source artwork. Regenerate the bundled icon after changing it:

```bash
scripts/generate-icons.sh
```

The icon script requires `rsvg-convert` and produces `Assets/AppIcon.icns`. Install it with:

```bash
brew install librsvg
```

## Repository layout

```text
App/                    Application source
Assets/                 App icon source and generated .icns file
Info.plist              App bundle metadata and Location Services usage text
build.sh                Compile, package, sign, and launch the app
scripts/generate-icons.sh
                        Generate the .icns file from the SVG source
```

## License

This project is licensed under the [MIT License](LICENSE).
