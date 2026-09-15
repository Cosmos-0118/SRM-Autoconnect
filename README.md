# SRM Autoconnect

SRM Autoconnect is a macOS menu-bar app for the SRMIST Wi-Fi captive portal. When it detects the Wi-Fi network named `SRMIST`, it checks whether the internet is genuinely reachable. If not, it opens the SRM portal in an invisible WebKit view, submits the saved SRM credentials, and verifies that the connection is usable before reporting success.

The app has no Dock icon and no main window. Click the Wi-Fi icon in the menu bar to open its dashboard, logs, and settings.

## What the app actually monitors

The app considers only the Wi-Fi SSID `SRMIST` to be an SRM network. It reads the SSID with CoreWLAN, polls it every five seconds, listens for network-path changes, and checks again five seconds after the Mac wakes.

On macOS 14 and later, macOS requires Location Services permission before an app can read the current Wi-Fi name. Without that permission, SRM Autoconnect cannot automatically identify `SRMIST`.

While connected to `SRMIST`, the app probes external sites to decide whether the internet is available. It requires at least two of these three checks to pass:

- `https://example.com` contains `Example Domain`
- `https://cloudflare.com/cdn-cgi/trace` contains `fl=`
- `https://api.github.com/zen` responds successfully

It also checks Apple's captive-portal page only to tell a captive-portal interception from a general outage. An Apple connectivity response alone is never treated as proof of internet access.

## Login behavior

When the probes show that the internet is unavailable, the app:

1. Loads `https://iac.srmist.edu.in/Connect/PortalMain` in an off-screen `WKWebView`.
2. Refuses to inject credentials unless the loaded page remains HTTPS on `iac.srmist.edu.in` and uses the default HTTPS port.
3. Finds the password field and a text, email, or telephone username field in the same form.
4. Sets both fields and dispatches `input` and `change` events so portal pages with framework-managed form state receive the update.
5. Activates a submit control, then repeatedly checks internet reachability to confirm the portal actually opened access.

An attempt has a 45-second watchdog. A failed attempt retries after approximately 3, 8, 20, and 45 seconds (with a small random delay). After those retries are exhausted, the next automatic attempt is delayed for 1, 3, 5, then 10 minutes. Leaving `SRMIST` cancels an in-progress login and discards pending retries.

**Force Connect** clears the current retry backoff and starts an attempt immediately. It may be used even when the current SSID is not `SRMIST`; the app still performs its normal internet check before loading the portal.

## Credentials, notifications, and logs

Enter your SRM ID and password on the **Settings** tab. They are stored as macOS generic-password Keychain items under the service `SRMAutoconnect`, with the accounts `username` and `password`, and are accessible only while the Mac is unlocked. The password is not loaded back into the settings UI.

At launch, the app requests permission for alerts and sounds. After a verified successful login, it shows a `Connected to SRM Wi-Fi` notification and plays the macOS `Glass` sound.

The dashboard persists its success count, failure count, and last successful connection time in `UserDefaults`. The **Logs** tab shows up to 300 recent user-facing events and can copy them to the clipboard. Diagnostic messages are written to:

```text
~/Library/Logs/SRMAutoconnect.log
```

The file rotates at roughly 1 MB, keeping one previous file as `SRMAutoconnect.log.1`.

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
