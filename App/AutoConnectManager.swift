import Foundation
import WebKit
import Combine
import AppKit

final class AutoConnectManager: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AutoConnectManager()

    @Published var totalSuccesses: Int {
        didSet { UserDefaults.standard.set(totalSuccesses, forKey: "totalSuccesses") }
    }
    @Published var totalFailures: Int {
        didSet { UserDefaults.standard.set(totalFailures, forKey: "totalFailures") }
    }
    @Published var lastConnectedTime: Date? {
        didSet { UserDefaults.standard.set(lastConnectedTime, forKey: "lastConnectedTime") }
    }
    @Published var isConnecting: Bool = false

    /// When the next automatic attempt is allowed. Surfaced in the dashboard so a
    /// deliberate backoff doesn't look like the app has silently stopped working.
    @Published var nextAttemptAt: Date?

    /// `alreadyOnline` is distinct from `success` because no login happened. It
    /// used to report plain success, so Force Connect on a working connection
    /// claimed to have connected you.
    enum LoginResult { case success, alreadyOnline, failure }
    /// Drives a transient banner in DashboardView — otherwise a login attempt resolves
    /// with nothing visible in the UI beyond the spinner disappearing.
    @Published var lastResult: LoginResult?
    /// Why the last attempt failed, in the user's words. The banner previously
    /// said only "LOGIN FAILED — CHECK CREDENTIALS" no matter the cause, which
    /// is actively misleading when the real reason was that the portal was
    /// unreachable or the network had not come up yet.
    @Published var lastFailureReason: String?
    private var resultClearWorkItem: DispatchWorkItem?

    // MARK: - Attempt lifecycle
    //
    // Every asynchronous continuation (navigation callback, timeout, retry, probe
    // result) is tagged with the attempt token it belongs to and drops itself if
    // that token is no longer current. Without this, a stale 20s timeout from a
    // superseded attempt could call recordFailure() against a live attempt, and a
    // single attempt could fail twice (navigation error *and* timeout) — each
    // failure scheduling its own retry, so the retry chains multiplied instead of
    // running one at a time.
    private var currentAttempt: Int = 0
    private var currentAttemptWasForced = false
    private var attemptStartedAt = ProcessInfo.processInfo.systemUptime
    private var phaseStartedAt = ProcessInfo.processInfo.systemUptime

    private var retryCount = 0
    /// Invalidates delayed retry closures. Merely clearing `nextAttemptAt` is not
    /// enough: the closure is already queued and could fire after a Force Connect
    /// or after leaving then rejoining SRMIST.
    private var retryScheduleGeneration = 0
    private let retryDelays: [Double] = [3, 8, 20, 45]
    /// Set when any navigation in the current attempt failed with
    /// NSURLErrorNotConnectedToInternet (-1009) — macOS reporting no route at all,
    /// not the portal being unreachable. This fires reliably right after joining
    /// Wi-Fi (DHCP/routing hasn't come up yet) and right after waking from sleep,
    /// and it looks identical to a dead portal in the logs ("connection appears to
    /// be offline"). Retrying it on the same ladder as a genuinely down portal
    /// meant a normal join could burn most of the retry budget before the OS
    /// caught up. A short, separate ladder retries it fast; if it still isn't
    /// ready after that, it falls through to the normal ladder below.
    private var sawNetworkNotReadyInAttempt = false
    private var networkNotReadyRetries = 0
    private let networkNotReadyDelays: [Double] = [1, 2, 3]
    /// After a whole retry chain is exhausted, back off hard. Previously the 15s
    /// reachability poll restarted the chain immediately, so a portal that was
    /// genuinely down got hammered continuously.
    private let giveUpCooldowns: [TimeInterval] = [60, 180, 300, 600]
    private var consecutiveGiveUps = 0
    /// An attempt has phase-specific watchdogs below. This is only the final
    /// safety net for an unexpected WebKit/JavaScript state that never reports
    /// its own outcome.
    // The bounded phases can legitimately total a little over 100 seconds in
    // the worst case (preflight + navigation + form discovery + five network
    // verification probes). Keep this above that ceiling so it remains a true
    // deadlock safety net rather than pre-empting a healthy verification loop.
    private let attemptHardTimeout: TimeInterval = 120
    private let portalNavigationTimeout: TimeInterval = 18
    private let loginFormTimeout: TimeInterval = 25
    /// How long to stop retrying when the blocker is the user, not the network.
    private let missingCredentialsBackoff: TimeInterval = 300

    private var webView: WKWebView!
    private var hostWindow: NSWindow!

    private enum AttemptPhase: Equatable {
        case idle
        case preflight
        case loadingPortal
        case waitingForLoginForm
        case waitingForPortalHandler
        case verifying
    }
    private var attemptPhase: AttemptPhase = .idle

    /// Credentials are submitted only to the known HTTPS portal. An HTTP captive
    /// portal fallback can be attacker-controlled, so it must never be allowed to
    /// receive the Keychain password.
    private let portalCandidates: [URL] = [
        URL(string: "https://iac.srmist.edu.in/Connect/PortalMain")!
    ]
    private let trustedPortalHosts: Set<String> = ["iac.srmist.edu.in"]
    private var portalIndex = 0
    private var navigationAttempts: [ObjectIdentifier: Int] = [:]
    private var activePortalNavigation: ObjectIdentifier?
    private var injectedNavigation: ObjectIdentifier?
    private var loginSubmittedForAttempt = -1
    /// Per-candidate errors for the attempt in progress, so a final "portal
    /// unreachable" line retains its real cause rather than just its last error.
    private var portalFailures: [String] = []

    private lazy var reachabilityProbe = ReachabilityProbe(diagnostic: { Logger.shared.debug($0) })

    private override init() {
        self.totalSuccesses = UserDefaults.standard.integer(forKey: "totalSuccesses")
        self.totalFailures = UserDefaults.standard.integer(forKey: "totalFailures")
        self.lastConnectedTime = UserDefaults.standard.object(forKey: "lastConnectedTime") as? Date

        super.init()

        let config = WKWebViewConfiguration()
        // The injected script reports its own outcome instead of us guessing after a
        // fixed sleep, so "the form never appeared" and "we submitted and are waiting"
        // are distinguishable failures.
        config.userContentController.add(self, name: "srm")

        // A WKWebView with no window ever attached silently stalls navigation on
        // macOS — it never calls back (no didFinish, no didFail). Hosting it in a
        // real (offscreen, invisible) window fixes that.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.navigationDelegate = self

        hostWindow = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = webView
        hostWindow.orderBack(nil)

        Logger.shared.debug("Log file: \(Logger.shared.logFilePath)")
    }

    // MARK: - Entry point

    /// `force` is the Force Connect button: it ignores any active backoff and resets
    /// the retry chain. Automatic triggers must not, or they defeat the backoff.
    func attemptLogin(force: Bool = false) {
        attemptLogin(force: force, knownReachability: nil)
    }

    /// NetworkMonitor has already performed the expensive reachability probe when
    /// it calls this entry point. Reusing that result avoids immediately issuing
    /// the same four requests again and mistaking one short network flap for two
    /// independent confirmations that the internet is down.
    func attemptLogin(afterConfirmedOutage state: Reachability) {
        attemptLogin(force: false, knownReachability: state)
    }

    private func attemptLogin(force: Bool, knownReachability: Reachability?) {
        if Thread.isMainThread {
            startLogin(force: force, knownReachability: knownReachability)
        } else {
            DispatchQueue.main.async {
                self.startLogin(force: force, knownReachability: knownReachability)
            }
        }
    }

    private func startLogin(force: Bool, knownReachability: Reachability?) {
        // All mutable attempt state lives on the main thread, so the guard below and
        // the `isConnecting = true` that follows are atomic with respect to each
        // other. The old code checked the guard, then hopped to main to set the flag
        // — two triggers arriving in the same runloop turn both got through.
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isConnecting else {
            Logger.shared.debug("Login already in flight — ignoring trigger.")
            return
        }

        // Retry timers call this same entry point. Without this guard, an
        // automatic retry scheduled on SRMIST continued to load the portal after
        // the computer had roamed to a hotspot or a home network.
        guard force || NetworkMonitor.shared.isReadyForAutomaticLogin else {
            Logger.shared.debug("SRMIST network is not ready — skipping automatic portal login.")
            return
        }

        if force {
            retryScheduleGeneration &+= 1
            nextAttemptAt = nil
            retryCount = 0
            consecutiveGiveUps = 0
            networkNotReadyRetries = 0
        } else if let until = nextAttemptAt, until > Date() {
            Logger.shared.debug("Backing off for another \(Int(until.timeIntervalSinceNow))s — skipping trigger.")
            return
        }

        // Every bail-out below reports itself. These paths used to just log and
        // return, so pressing FORCE CONNECT with nothing saved changed no
        // published state whatsoever and the dashboard sat there as though the
        // click had not happened. They also set no backoff, so with no
        // credentials the reachability poll went on probing four hosts every ten
        // seconds, forever, to reach a function that could never do anything.
        let creds: (username: String, password: String)?
        do {
            creds = try credentials()
        } catch let failure as KeychainHelper.KeychainFailure {
            // Saved but unreadable (denied ACL, locked keychain) — different
            // from "never saved", and re-saving alone won't fix it.
            let message = "Cannot read saved credentials (\(failure.errorDescription ?? "keychain error")). \(KeychainHelper.hint(for: failure.status))"
            Logger.shared.log(message)
            reportBlocked("keychain unreadable — open Settings")
            return
        } catch {
            Logger.shared.log("Cannot read saved credentials (\(error.localizedDescription)).")
            reportBlocked("keychain unreadable — open Settings")
            return
        }
        guard creds != nil else {
            Logger.shared.log("Credentials not set — open Settings and save your SRM ID and password.")
            reportBlocked("no credentials saved — open Settings")
            return
        }

        currentAttempt &+= 1
        let token = currentAttempt
        portalIndex = 0
        navigationAttempts.removeAll(keepingCapacity: true)
        activePortalNavigation = nil
        injectedNavigation = nil
        loginSubmittedForAttempt = -1
        portalFailures = []
        sawNetworkNotReadyInAttempt = false
        currentAttemptWasForced = force
        attemptStartedAt = ProcessInfo.processInfo.systemUptime
        phaseStartedAt = attemptStartedAt
        Logger.shared.debug("Attempt \(token) trigger=\(force ? "force" : (knownReachability == nil ? "preflight/retry" : "confirmed-outage")) started")
        transition(to: .preflight)
        isConnecting = true
        nextAttemptAt = nil

        let ssid = NetworkMonitor.shared.currentSSID
        if !NetworkMonitor.isSRMNetwork(ssid) {
            Logger.shared.debug("Current network is '\(ssid.isEmpty ? "none" : ssid)', not SRMIST — attempting anyway.")
        }

        // Hard watchdog. Whatever goes wrong downstream — a navigation that never
        // calls back, a JS handler that never reports — the attempt is guaranteed
        // to resolve and release `isConnecting`.
        after(attemptHardTimeout, token) {
            self.fail(token, "attempt timed out after \(Int(self.attemptHardTimeout))s")
        }

        // A captive portal only exists until you are actually online. If some other
        // path already has real internet, running the login sequence is pointless
        // and burns the retry chain for nothing.
        if let knownReachability {
            continueLogin(token, reachability: knownReachability)
        } else {
            probeReachability(quiet: true) { [weak self] state in
                self?.continueLogin(token, reachability: state)
            }
        }
    }

    private func continueLogin(_ token: Int, reachability state: Reachability) {
        guard isLive(token) else { return }

        if state.online {
            Logger.shared.debug("Internet already reachable — no portal login needed.")
            finish(token)
            retryCount = 0
            consecutiveGiveUps = 0
            networkNotReadyRetries = 0
            // Deliberately not a success: nothing was logged in, so counting
            // it would inflate the Success metric and move LAST CONNECTED
            // every time the poll happened to run while things were fine.
            lastFailureReason = nil
            showResult(.alreadyOnline)
            return
        }

        Logger.shared.log(state.captivePortal
            ? "Captive portal detected. Logging in..."
            : "No internet (\(state.detail)). Starting portal login...")
        loadPortal(token)
    }

    // MARK: - Portal navigation

    private func loadPortal(_ token: Int) {
        guard isLive(token), portalIndex < portalCandidates.count else {
            fail(token, "no portal URL reachable")
            return
        }
        let url = portalCandidates[portalIndex]
        Logger.shared.debug("Loading portal candidate \(portalIndex + 1)/\(portalCandidates.count): \(url.absoluteString)")
        transition(to: .loadingPortal)
        webView.stopLoading()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if let navigation = webView.load(request) {
            let navigationID = ObjectIdentifier(navigation)
            navigationAttempts[navigationID] = token
            activePortalNavigation = navigationID
            armPortalNavigationTimeout(token, navigationID: navigationID)
        } else {
            advancePortal(token, reason: "WebKit could not start navigation")
        }
    }

    private func armPortalNavigationTimeout(_ token: Int, navigationID: ObjectIdentifier) {
        after(portalNavigationTimeout, token) { [weak self] in
            guard let self,
                  self.attemptPhase == .loadingPortal,
                  self.activePortalNavigation == navigationID else { return }
            self.advancePortal(
                token,
                navigationID: navigationID,
                reason: "navigation timed out after \(Int(self.portalNavigationTimeout))s"
            )
        }
    }

    /// Move to the next portal URL rather than failing the whole attempt: the first
    /// candidate failing is the normal case behind a portal that breaks TLS.
    private func advancePortal(_ token: Int, navigationID: ObjectIdentifier? = nil, reason: String) {
        guard isLive(token) else { return }
        guard portalIndex < portalCandidates.count else {
            fail(token, "no portal URL reachable")
            return
        }
        if let navigationID {
            guard navigationAttempts[navigationID] == token else { return }
            navigationAttempts.removeValue(forKey: navigationID)
        } else if let activePortalNavigation {
            navigationAttempts.removeValue(forKey: activePortalNavigation)
        }
        activePortalNavigation = nil
        let host = portalCandidates[portalIndex].host ?? "candidate \(portalIndex + 1)"
        portalFailures.append("\(host): \(reason)")
        Logger.shared.debug("Portal candidate \(portalIndex + 1) failed (\(reason)).")
        portalIndex += 1
        if portalIndex < portalCandidates.count {
            loadPortal(token)
        } else {
            fail(token, "portal unreachable — \(portalFailures.joined(separator: "; "))")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let token = currentAttempt
        guard isLive(token), belongsToLiveAttempt(navigation, token: token) else {
            Logger.shared.debug("Ignoring completion from a superseded portal navigation.")
            return
        }
        let url = redacted(webView.url)
        Logger.shared.debug("Loaded: \(url)")

        guard loginSubmittedForAttempt != token else {
            // A gateway commonly redirects away from its login host after it
            // accepts credentials. The queued reachability verification, not this
            // destination, is the authoritative result.
            Logger.shared.debug("Post-submit navigation to: \(url)")
            return
        }

        guard isTrustedPortalURL(webView.url) else {
            advancePortal(
                token,
                navigationID: ObjectIdentifier(navigation),
                reason: "redirected outside the trusted HTTPS SRM portal"
            )
            return
        }

        let navigationID = ObjectIdentifier(navigation)
        guard injectedNavigation != navigationID else { return }
        injectedNavigation = navigationID
        transition(to: .waitingForLoginForm)
        injectLogin(token)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isConnecting else { return }
        // This covers same-attempt JavaScript/meta redirects, whose WKNavigation
        // differs from the explicit `webView.load` navigation.
        let navigationID = ObjectIdentifier(navigation)
        navigationAttempts[navigationID] = currentAttempt
        activePortalNavigation = navigationID
        if attemptPhase == .loadingPortal {
            armPortalNavigationTimeout(currentAttempt, navigationID: navigationID)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(navigation, error: error, phase: "navigation")
    }

    /// Previously missing entirely. Provisional failures are where *every* real
    /// network-level error lands — DNS failure, connection refused, TLS rejection —
    /// so all of them were invisible and only surfaced as a bare timeout with no
    /// cause. This is why the logs showed timeouts and never a single load.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(navigation, error: error, phase: "connection")
    }

    private func handleNavigationError(_ navigation: WKNavigation!, error: Error, phase: String) {
        let token = currentAttempt
        guard isLive(token), belongsToLiveAttempt(navigation, token: token) else {
            Logger.shared.debug("Ignoring failure from a superseded portal navigation.")
            return
        }
        guard loginSubmittedForAttempt != token else {
            Logger.shared.debug("Post-submit navigation failed; awaiting reachability verification.")
            return
        }
        let ns = error as NSError
        // -999 is "cancelled", which we cause ourselves via stopLoading() or by
        // superseding a navigation. It is not a failure.
        guard ns.code != NSURLErrorCancelled else { return }

        if ns.code == NSURLErrorNotConnectedToInternet {
            sawNetworkNotReadyInAttempt = true
        }

        if ns.code == NSURLErrorServerCertificateUntrusted
            || ns.code == NSURLErrorServerCertificateHasBadDate
            || ns.code == NSURLErrorSecureConnectionFailed {
            Logger.shared.debug("TLS rejected by the portal gateway.")
        }
        advancePortal(
            token,
            navigationID: ObjectIdentifier(navigation),
            reason: "\(phase): \(error.localizedDescription)"
        )
    }

    private func belongsToLiveAttempt(_ navigation: WKNavigation!, token: Int) -> Bool {
        guard let navigation else { return false }
        return navigationAttempts[ObjectIdentifier(navigation)] == token
    }

    /// Scheme, host and path only. The log file lives at a readable path in
    /// ~/Library/Logs and is meant to be pasted into a support thread, and a
    /// portal whose login form submits by GET puts the username and password
    /// straight into the query string — which the post-submit navigation would
    /// then have written there verbatim.
    private func redacted(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.host ?? "(url)"
        }
        let hadQuery = !(parts.percentEncodedQuery ?? "").isEmpty
        let hadFragment = !(parts.percentEncodedFragment ?? "").isEmpty
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        let base = parts.string ?? url.host ?? "(url)"
        return base + (hadQuery || hadFragment ? " (query redacted)" : "")
    }

    private func isTrustedPortalURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), trustedPortalHosts.contains(host),
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    // MARK: - Credential injection

    private func credentials() throws -> (username: String, password: String)? {
        let u = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "username")
        let p = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "password")
        guard let u, let p,
              let username = String(data: u, encoding: .utf8),
              let password = String(data: p, encoding: .utf8),
              !username.isEmpty, !password.isEmpty else { return nil }
        return (username, password)
    }

    /// Credentials used to be interpolated raw into the script source, so a single
    /// quote or backslash in a password produced a JS syntax error and the whole
    /// injection silently did nothing. JSON encoding gives a guaranteed-valid
    /// literal for any input.
    private func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let wrapped = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(wrapped.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private func injectLogin(_ token: Int) {
        let creds: (username: String, password: String)?
        do {
            creds = try credentials()
        } catch let failure as KeychainHelper.KeychainFailure {
            fail(token, "keychain unreadable (\(failure.errorDescription ?? "keychain error"))")
            return
        } catch {
            fail(token, "keychain unreadable (\(error.localizedDescription))")
            return
        }
        guard let creds else {
            fail(token, "credentials unavailable")
            return
        }

        let js = """
        (function() {
          function report(stage, detail) {
            try { window.webkit.messageHandlers.srm.postMessage({ attempt: \(token), stage: stage, detail: String(detail || '') }); } catch (e) {}
          }
          function setValue(el, val) {
            // Portals built on React/Angular ignore a plain `.value =` assignment;
            // going through the native setter plus input/change events is what makes
            // the framework's own state actually update.
            try {
              var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
              if (d && d.set) { d.set.call(el, val); } else { el.value = val; }
            } catch (e) { el.value = val; }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          function looksLoggedIn() {
            var t = (document.body ? document.body.innerText : '').toLowerCase();
            return t.indexOf('logout') >= 0 || t.indexOf('sign out') >= 0 || t.indexOf('you are signed in') >= 0;
          }

          function isVisible(el) {
            if (!el) return false;
            try {
              var style = window.getComputedStyle(el);
              return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
            } catch (e) { return true; }
          }

          function isClickable(el) {
            var tag = (el.tagName || '').toLowerCase();
            if (!isVisible(el) || el.disabled) return false;
            if (tag === 'button' || tag === 'a') return true;
            if (tag !== 'input') return false;
            var t = (el.type || '').toLowerCase();
            return t === 'submit' || t === 'button' || t === 'image' || t === 'reset';
          }

          function findSubmit(scope) {
            // SRM's live portal deliberately does not submit this form as HTML.
            // Its login action encrypts the password and sends an AJAX request
            // through this handler. Recognized SRM forms wait for it below;
            // generic submit controls remain available for other form variants.
            var selectors = [
              '#UserCheck_Login_Button',
              '[onclick*="submitActiveForm"]',
              'input[type="submit"]', 'button[type="submit"]',
              'input[id*="login" i]', 'button[id*="login" i]',
              'a[id*="login" i]', 'a[name*="login" i]',
              'input[name*="login" i]', 'input[value*="login" i]',
              'input[id*="submit" i]', 'button[id*="submit" i]',
              'a[id*="submit" i]', 'input[type="button"]', 'button'
            ];
            var roots = [scope];
            if (scope !== document) roots.push(document);
            for (var r = 0; r < roots.length; r++) {
              for (var s = 0; s < selectors.length; s++) {
                var found;
                try { found = roots[r].querySelectorAll(selectors[s]); } catch (e) { continue; }
                for (var j = 0; j < found.length; j++) {
                  if (isClickable(found[j])) return found[j];
                }
              }
            }
            return null;
          }

          var started = Date.now();
          var reportedWaiting = false;
          var timer = setInterval(function() {
            var expired = Date.now() - started >= 24000;
            var pass = document.querySelector('input[type="password"]');
            if (!pass) {
              if (looksLoggedIn()) { clearInterval(timer); report('already', document.title); return; }
              if (expired) { clearInterval(timer); report('nofields', 'no password field after 24s'); }
              return;
            }
            // Scope to the password field's own form so a stray search box or a
            // second form on the page can't be mistaken for the username input.
            var scope = pass.form || document;
            var user = null;
            var inputs = scope.querySelectorAll('input');
            for (var i = 0; i < inputs.length; i++) {
              var t = (inputs[i].type || 'text').toLowerCase();
              if (t === 'text' || t === 'email' || t === 'tel') { user = inputs[i]; break; }
            }
            if (!user) {
              if (expired) { clearInterval(timer); report('nofields', 'no username field after 24s'); }
              return;
            }

            // SRM renders fields before its authentication scripts are ready.
            // Its anchor/form identify a handler-based portal even before the
            // global object exists. Never dispatch a generic click in that state.
            var needsHandler = !!document.querySelector('#UserCheck_Login_Button, #LoginUserPassword_auth_form, [onclick*="submitActiveForm"]');
            var handlerReady = window.oAuthentication && typeof window.oAuthentication.submitActiveForm === 'function';
            if (needsHandler && !handlerReady) {
              if (!reportedWaiting) { reportedWaiting = true; report('waitinghandler', 'authentication scripts loading'); }
              if (expired) { clearInterval(timer); report('handlernotready', 'portal authentication not ready after 24s'); }
              return;
            }

            clearInterval(timer);
            setValue(user, \(jsLiteral(creds.username)));
            setValue(pass, \(jsLiteral(creds.password)));

            // The SRM portal's normal path is not a DOM form submit. Calling
            // this handler is what applies its RSA password encryption and posts
            // to its Login endpoint. Native form.submit() would bypass both and
            // can make valid credentials look rejected.
            try {
              if (handlerReady) {
                report('handlerready', 'authentication handler callable');
                window.oAuthentication.submitActiveForm();
                report('submitted', 'oAuthentication.submitActiveForm');
                return;
              }
            } catch (e) { report('submiterror', 'portal authentication handler failed'); return; }

            var btn = findSubmit(scope);
            // Report what was clicked by its identity, never by its value: on a
            // form where the chosen control carries user-entered text, that value
            // would be written verbatim into the on-disk log.
            if (btn) { btn.click(); report('submitted', (btn.tagName || '') + '#' + (btn.id || '') + '.' + (btn.type || '')); }
            else if (pass.form) {
              if (typeof pass.form.requestSubmit === 'function') pass.form.requestSubmit();
              else pass.form.submit();
              report('submitted', 'native form request');
            }
            else { report('nosubmit', 'no submit control found'); }
          }, 500);
        })();
        """

        after(loginFormTimeout, token) { [weak self] in
            guard let self,
                  self.attemptPhase == .waitingForLoginForm || self.attemptPhase == .waitingForPortalHandler else { return }
            self.fail(token, self.attemptPhase == .waitingForPortalHandler
                ? "portal authentication did not become ready after \(Int(self.loginFormTimeout))s"
                : "login form did not become ready after \(Int(self.loginFormTimeout))s")
        }

        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let self, self.isLive(token) else { return }
            if let error {
                self.fail(token, "script injection failed: \(error.localizedDescription)")
            } else {
                Logger.shared.debug("Login script injected; waiting for form.")
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let token = currentAttempt
        guard isLive(token),
              let body = message.body as? [String: Any],
              let attempt = body["attempt"] as? Int,
              attempt == token,
              let stage = body["stage"] as? String else { return }
        let detail = (body["detail"] as? String) ?? ""

        switch stage {
        case "waitinghandler":
            guard loginSubmittedForAttempt != token else { return }
            transition(to: .waitingForPortalHandler)
        case "handlerready":
            guard loginSubmittedForAttempt != token else { return }
            transition(to: .waitingForLoginForm)
            Logger.shared.debug("Attempt \(token) authentication handler ready")
        case "submitted":
            guard loginSubmittedForAttempt != token else { return }
            loginSubmittedForAttempt = token
            transition(to: .verifying)
            Logger.shared.debug("Attempt \(token) submit dispatched via '\(detail)'; verifying internet")
            verify(token, remaining: 5)
        case "already":
            guard loginSubmittedForAttempt != token else { return }
            loginSubmittedForAttempt = token
            transition(to: .verifying)
            Logger.shared.debug("Portal reports an existing session. Verifying...")
            verify(token, remaining: 3)
        case "nofields":
            fail(token, "login form never appeared (\(detail))")
        case "nosubmit":
            fail(token, "no submit button on the login form")
        case "handlernotready":
            fail(token, "portal authentication did not become ready after 24s")
        case "submiterror":
            fail(token, "portal authentication handler failed before verification")
        default:
            Logger.shared.debug("Script reported '\(stage)': \(detail)")
        }
    }

    // MARK: - Verification

    /// Polls rather than taking a single reading after a fixed sleep: the gateway
    /// takes an unpredictable moment to actually open after accepting the form, and
    /// one early probe was being counted as an outright login failure.
    private func verify(_ token: Int, remaining: Int) {
        guard isLive(token) else { return }
        transition(to: .verifying)
        Logger.shared.debug("Attempt \(token) verification checks remaining=\(remaining)")
        probeReachability(quiet: true) { [weak self] state in
            guard let self, self.isLive(token) else { return }
            if state.online {
                self.succeed(token)
            } else if remaining > 1 {
                self.after(3, token) { self.verify(token, remaining: remaining - 1) }
            } else {
                self.fail(token, state.captivePortal
                    ? "portal still intercepting — credentials likely rejected (\(state.detail))"
                    : "no internet after login (\(state.detail))")
            }
        }
    }

    // MARK: - Reachability

    typealias Reachability = ReachabilityProbe.Result

    func probeInternet(completion: @escaping (Bool) -> Void) {
        probeReachability(quiet: true) { completion($0.online) }
    }

    func probeReachability(quiet: Bool = false, completion: @escaping (Reachability) -> Void) {
        if !quiet { Logger.shared.log("Verifying internet connectivity...") }
        reachabilityProbe.run { state in
            Logger.shared.debug("Reachability: \(state.online ? "online" : "offline") — \(state.detail)")
            if !quiet && !state.online { Logger.shared.log("No internet. (\(state.detail))") }
            completion(state)
        }
    }

    // MARK: - Attempt resolution

    private func transition(to phase: AttemptPhase) {
        guard phase != attemptPhase else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if attemptPhase != .idle {
            Logger.shared.debug("Attempt \(currentAttempt) phase=\(attemptPhase) elapsed=\(String(format: "%.3f", now - phaseStartedAt))s total=\(String(format: "%.3f", now - attemptStartedAt))s")
        }
        attemptPhase = phase
        phaseStartedAt = now
        if phase != .idle { Logger.shared.debug("Attempt \(currentAttempt) phase=\(phase) started") }
    }

    /// A continuation belongs to the live attempt only if its token is still current
    /// *and* that attempt has not already resolved.
    private func isLive(_ token: Int) -> Bool {
        Thread.isMainThread ? (token == currentAttempt && isConnecting) : false
    }

    private func after(_ delay: TimeInterval, _ token: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isLive(token) else { return }
            body()
        }
    }

    /// Resolves the attempt. Bumping the token here is what makes every outstanding
    /// callback from this attempt a no-op, so nothing can resolve it twice.
    private func finish(_ token: Int) {
        guard isLive(token) else { return }
        transition(to: .idle)
        currentAttempt &+= 1
        isConnecting = false
        navigationAttempts.removeAll(keepingCapacity: true)
        activePortalNavigation = nil
        webView.stopLoading()
    }

    /// Called by NetworkMonitor after a confirmed transition away from SRMIST.
    /// Cancelling is intentionally not a failed login: no credentials were proven
    /// wrong and no retry should be carried onto an unrelated network. Token
    /// invalidation also makes outstanding WebKit, probe, and timeout callbacks
    /// harmless.
    func cancelAutomaticLoginForNetworkChange() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.cancelAutomaticLoginForNetworkChange() }
            return
        }

        if isConnecting {
            let token = currentAttempt
            finish(token)
            Logger.shared.debug("Left SRMIST — cancelled portal login in progress.")
        }

        // A queued retry has no work item to cancel, but clearing its state means
        // its eventual callback is a no-op off SRMIST and a later SRMIST join gets
        // a fresh retry budget.
        if nextAttemptAt != nil {
            Logger.shared.debug("Left SRMIST — discarded pending portal retry.")
        }
        retryScheduleGeneration &+= 1
        nextAttemptAt = nil
        retryCount = 0
        consecutiveGiveUps = 0
        networkNotReadyRetries = 0
    }

    /// A retained SSID is not proof that the interface is usable during roaming.
    /// Abort an automatic attempt as soon as NetworkMonitor loses a usable SSID
    /// observation or satisfied path. This is a cancellation, not a failed login:
    /// no portal or credential decision was actually reached. Force Connect is
    /// deliberately exempt because the user explicitly asked for that diagnostic
    /// attempt even if the monitor currently distrusts the network state.
    func cancelAutomaticLoginForReadinessLoss() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.cancelAutomaticLoginForReadinessLoss() }
            return
        }
        // A user-forced attempt is deliberately allowed to finish so the button
        // remains a useful diagnostic escape hatch. Automatic work, including a
        // queued retry with no attempt currently in flight, must pause here.
        guard !currentAttemptWasForced || !isConnecting else { return }
        if isConnecting {
            finish(currentAttempt)
            Logger.shared.debug("Network readiness was lost — cancelled automatic portal login in progress.")
        }

        // A retry timer scheduled while the path was usable must not consume a
        // retry rung while the interface is down. The path-recovery callback will
        // start a fresh reachability check instead.
        if nextAttemptAt != nil {
            retryScheduleGeneration &+= 1
            nextAttemptAt = nil
            Logger.shared.debug("Network readiness was lost — paused pending portal retry.")
        }
    }

    /// Called when the user saves or removes credentials. Without this, fixing a
    /// mistyped password did nothing for up to ten minutes: the failures it
    /// caused had already walked the app into a give-up cooldown, and nothing in
    /// the save path cleared it — so the app sat there with correct credentials
    /// and refused to use them, which reads exactly like the save not working.
    func credentialsChanged() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.credentialsChanged() }
            return
        }
        retryScheduleGeneration &+= 1
        nextAttemptAt = nil
        retryCount = 0
        consecutiveGiveUps = 0
        networkNotReadyRetries = 0
        lastResult = nil
        lastFailureReason = nil
        Logger.shared.debug("Credentials changed — cleared backoff.")
        if NetworkMonitor.shared.isConnectedToSRM {
            attemptLogin()
        }
    }

    /// Called after a system wake. A retry timer scheduled before sleep would
    /// otherwise fire the instant the run loop resumes — before the Wi-Fi
    /// interface has had any chance to reassociate and get a DHCP lease — turning
    /// a normal wake into a guaranteed extra failure that eats into the retry
    /// budget. NetworkMonitor's own post-wake settle delay drives the next
    /// attempt instead.
    func cancelPendingRetryForWake() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.cancelPendingRetryForWake() }
            return
        }
        // An attempt that was in flight when the machine went to sleep began on
        // whatever network existed before sleep, and its WebKit navigation is now
        // meaningless. Previously this function ignored that case entirely: it
        // only looked at `nextAttemptAt`, so the stale attempt kept `isConnecting`
        // true and blocked every entry point until the final watchdog got round to
        // failing it — which also cost a rung of the retry ladder.
        if isConnecting {
            finish(currentAttempt)
            Logger.shared.debug("System woke — cancelled the portal login that was in flight before sleep.")
        }

        guard nextAttemptAt != nil || retryCount > 0 || networkNotReadyRetries > 0 else { return }
        retryScheduleGeneration &+= 1
        nextAttemptAt = nil
        // Reset the ladder rather than merely dropping the pending timer. Waking
        // up is a fresh start, not a continuation of whatever was failing before
        // sleep, and leaving the counters advanced meant each wake began one rung
        // further down the backoff — so a laptop opened a few times across a day
        // reached the 10-minute cooldown without a single genuine failure.
        retryCount = 0
        networkNotReadyRetries = 0
        Logger.shared.debug("System woke — discarded retry timer scheduled before sleep and reset the retry ladder.")
    }

    private func succeed(_ token: Int) {
        guard isLive(token) else { return }
        finish(token)
        Logger.shared.log("Connected.")
        retryCount = 0
        consecutiveGiveUps = 0
        networkNotReadyRetries = 0
        // Invalidate any give-up cooldown timer still queued from an earlier
        // failure. Without this it survives the success and fires minutes later,
        // launching an unwanted attempt on a connection that is already working.
        retryScheduleGeneration &+= 1
        nextAttemptAt = nil
        totalSuccesses += 1
        lastConnectedTime = Date()
        lastFailureReason = nil
        NotificationManager.shared.showConnectedToast()
        showResult(.success)
    }

    private func fail(_ token: Int, _ reason: String) {
        guard isLive(token) else { return }
        finish(token)

        // Count every resolved failed attempt. This used to increment only in
        // the give-up branch below, so Success counted attempts while Failed
        // counted whole give-up episodes — two different units side by side
        // under two labels that read as a matched pair, both parked near zero.
        totalFailures += 1
        lastFailureReason = reason

        if sawNetworkNotReadyInAttempt && networkNotReadyRetries < networkNotReadyDelays.count {
            let delay = networkNotReadyDelays[networkNotReadyRetries] + Double.random(in: 0...0.5)
            networkNotReadyRetries += 1
            Logger.shared.log("Network not ready yet (\(reason)). Retrying in \(Int(delay))s (\(networkNotReadyRetries)/\(networkNotReadyDelays.count)).")
            Logger.shared.debug("Attempt \(token) retry wait=\(String(format: "%.3f", delay))s")
            nextAttemptAt = Date().addingTimeInterval(delay)
            let generation = retryScheduleGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.retryScheduleGeneration == generation else { return }
                // Clear the deadline as soon as it is reached. attemptLogin()
                // only clears it on a path that actually starts an attempt, so
                // when the retry was skipped (off SRMIST, no credentials) the
                // stale date stayed published and the dashboard's NEXT ATTEMPT
                // row kept counting past zero, forever.
                self.nextAttemptAt = nil
                self.attemptLogin()
            }
            return
        }

        if retryCount < retryDelays.count {
            // Jitter keeps a flapping network from lining every retry up on the same
            // instant as the reachability poll.
            let delay = retryDelays[retryCount] + Double.random(in: 0...1.5)
            retryCount += 1
            Logger.shared.log("Login failed (\(reason)). Retry \(retryCount)/\(retryDelays.count) in \(Int(delay))s.")
            Logger.shared.debug("Attempt \(token) retry wait=\(String(format: "%.3f", delay))s")
            nextAttemptAt = Date().addingTimeInterval(delay)
            let generation = retryScheduleGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.retryScheduleGeneration == generation else { return }
                // Clear the deadline as soon as it is reached. attemptLogin()
                // only clears it on a path that actually starts an attempt, so
                // when the retry was skipped (off SRMIST, no credentials) the
                // stale date stayed published and the dashboard's NEXT ATTEMPT
                // row kept counting past zero, forever.
                self.nextAttemptAt = nil
                self.attemptLogin()
            }
        } else {
            let cooldown = giveUpCooldowns[min(consecutiveGiveUps, giveUpCooldowns.count - 1)]
            consecutiveGiveUps += 1
            retryCount = 0
            networkNotReadyRetries = 0
            Logger.shared.debug("Attempt \(token) cooldown wait=\(Int(cooldown))s")
            nextAttemptAt = Date().addingTimeInterval(cooldown)
            Logger.shared.log("Login failed (\(reason)). Giving up; next try in \(Int(cooldown / 60))m\(Int(cooldown) % 60)s.")
            showResult(.failure)
            // The cooldown is enforced by startLogin(); this timer just makes sure
            // something re-triggers even if no network event happens meanwhile.
            let generation = retryScheduleGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + cooldown + 1) { [weak self] in
                guard let self, self.retryScheduleGeneration == generation else { return }
                self.nextAttemptAt = nil
                guard !self.isConnecting, NetworkMonitor.shared.isReadyForAutomaticLogin else { return }
                self.attemptLogin()
            }
        }
    }

    /// Surfaces a pre-flight bail-out and parks the retry loop. Without the
    /// backoff the caller would be re-entered on every reachability poll.
    private func reportBlocked(_ reason: String) {
        lastFailureReason = reason
        showResult(.failure)
        nextAttemptAt = Date().addingTimeInterval(missingCredentialsBackoff)
    }

    private func showResult(_ result: LoginResult) {
        resultClearWorkItem?.cancel()
        lastResult = result
        // A failure sticks until something supersedes it. It used to erase
        // itself after five seconds of wall-clock time regardless of whether
        // anyone was looking — and since this app's window is a popover that is
        // shut almost all the time, that meant login failures were, in practice,
        // never seen. Successes still clear themselves; a stale green banner is
        // the one that misleads.
        guard result != .failure else { return }
        let workItem = DispatchWorkItem { [weak self] in self?.lastResult = nil }
        resultClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }
}
