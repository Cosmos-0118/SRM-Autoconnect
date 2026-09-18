import Foundation
import CoreWLAN
import AppKit
import CoreLocation
import Network

final class NetworkMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = NetworkMonitor()

    @Published var currentSSID: String = ""
    @Published var isConnectedToSRM: Bool = false

    /// Campus Wi-Fi is rarely a single exact name: SRMIST_5G, SRMIST-Student and
    /// similar all front the same portal. This used to be an exact-match set
    /// containing only "SRMIST", while AutoConnectManager judged the very same
    /// SSID with `uppercased().contains("SRMIST")` — so the two halves of the app
    /// disagreed about what network you were on, and every variant name was
    /// silently never auto-connected. One rule, used by both.
    ///
    /// Matching loosely is safe here because being on a matching SSID only
    /// decides whether to *look* for a portal. Credentials are still submitted
    /// exclusively to the pinned HTTPS host in `trustedPortalHosts`, so an
    /// access point that simply calls itself SRMIST-something cannot collect them.
    private static let srmSSIDToken = "SRMIST"

    static func isSRMNetwork(_ ssid: String) -> Bool {
        ssid.uppercased().contains(srmSSIDToken)
    }

    private var client: CWWiFiClient?
    private var locationManager: CLLocationManager?
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "com.srm.autoconnect.pathmonitor")
    private var lastPathStatus: NWPath.Status?
    /// An HTTP probe belongs to the Wi-Fi state that launched it, not whichever
    /// network happens to be active when its callbacks return.
    private var networkGeneration = 0

    /// CWInterface.ssid() intermittently returns nil while the interface is
    /// scanning or roaming — the logs showed SRMIST -> '' -> SRMIST cycling every
    /// few seconds. Each of those flaps was committed as a real disconnect and
    /// reconnect, and each reconnect fired a fresh login on top of the retry chain
    /// already running. Dropping to "no network" therefore has to be confirmed by
    /// consecutive reads; joining a real network still commits immediately, so
    /// there is no added latency on an actual join.
    private var pendingEmptyReads = 0
    private let emptyReadsToConfirm = 3
    /// The displayed SSID is deliberately retained across a couple of nil reads,
    /// but a nil read still means this instant is unsafe for new network work.
    /// Keeping these concepts separate prevents the debounce from launching a
    /// portal load while the interface is roaming or has no route.
    private var latestSSIDReadWasUsable = false

    /// Reachability is a real network fetch. The 15s timer and the path monitor can
    /// otherwise fire back to back and probe twice for one event.
    private var lastReachabilityCheck: Date?
    private var reachabilityProbeInFlight = false
    private var consecutiveOfflineProbes = 0
    private var offlineConfirmationWorkItem: DispatchWorkItem?
    private let offlineConfirmationDelay: TimeInterval = 3
    /// Throttle for the reachability probe. While we are known-good there is
    /// nothing to react to, so probing every 15s only burns battery, data, and
    /// third-party rate limits — a full probe is four HTTPS requests, and at 15s
    /// that is ~960 requests an hour, forever, for a machine that is already
    /// online. Back off hard once online and tighten up the moment we are not.
    private var reachabilityMinInterval: TimeInterval { lastProbeWasOnline ? 60 : 10 }
    private var lastProbeWasOnline = false
    private var warnedAboutTunnel = false
    /// Coalesces the several wake/unlock notifications macOS delivers together.
    private var lastWakeHandledAt: Date?

    /// Automatic attempts require both a retained SRM identity and evidence that
    /// the interface is usable right now. A force attempt intentionally bypasses
    /// this gate so the dashboard button remains a useful diagnostic escape hatch.
    var isReadyForAutomaticLogin: Bool {
        isConnectedToSRM
            && latestSSIDReadWasUsable
            && lastPathStatus == .satisfied
    }

    private override init() {
        super.init()
        self.client = CWWiFiClient.shared()

        // CoreWLAN has required Location Services authorization to return an SSID
        // since macOS 10.15, not macOS 14. Gating this behind `#available(macOS
        // 14.0, *)` meant that on macOS 13 — which this project's deployment
        // target and README both claim to support — the app never created a
        // location manager, never prompted, and so `interface.ssid()` returned
        // nil forever. That is indistinguishable from "not on Wi-Fi", so SRMIST
        // was never detected and auto-connect simply never fired. The deployment
        // target is 13.0, so this is now unconditional.
        self.locationManager = CLLocationManager()
        self.locationManager?.delegate = self
        self.locationManager?.requestWhenInUseAuthorization()

        setupNotifications()
        setupPathMonitor()
        updateNetworkStatus()
    }

    /// The modern spelling. `locationManager(_:didChangeAuthorization:)` has been
    /// deprecated since macOS 11, and when both exist CoreLocation calls only
    /// this one — so leaving just the old one around was a trap for whoever next
    /// added the new one and silently disabled the old.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange(manager.authorizationStatus)
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        // Without this permission ssid() returns nil forever, which is
        // indistinguishable from "not on Wi-Fi" — worth saying out loud.
        switch status {
        case .denied, .restricted:
            Logger.shared.log("Location permission denied — macOS won't report the Wi-Fi name, so SRMIST can't be detected automatically. Grant it in System Settings › Privacy & Security › Location Services.")
        case .notDetermined:
            // Previously silent, so the one state where the app is waiting on the
            // user looked exactly like the state where everything is fine.
            Logger.shared.log("Waiting for Location Services permission — macOS needs it before it will report the Wi-Fi name.")
        default:
            Logger.shared.debug("Location authorization status: \(status.rawValue)")
        }
        updateNetworkStatus()
    }

    private func setupNotifications() {
        // `didWakeNotification` alone is not enough. Over a 20-hour run it fired
        // 7 times while the timers were observably stalled on 54 separate
        // occasions: display sleep, screen lock and session switches all park
        // the app without ever producing a full system-wake notification. Each
        // of these is a moment where the Wi-Fi state may have changed under us,
        // so treat them all as "re-check now".
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(handleWakeNotification),
                name: name,
                object: nil
            )
        }

        // .common mode so both timers keep firing while the popover's menu tracking
        // run loop is active, instead of stalling whenever the UI is open.
        let ssidTimer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateNetworkStatus()
        }
        RunLoop.main.add(ssidTimer, forMode: .common)

        let reachTimer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkInternetIfNeeded()
        }
        RunLoop.main.add(reachTimer, forMode: .common)
    }

    /// Event-driven supplement to the timers: a path change (interface up/down,
    /// gained/lost connectivity) triggers an immediate check instead of waiting for
    /// the next tick. NWPathMonitor can't read SSID text, so it can't replace the
    /// SSID polling itself.
    private func setupPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                // NWPathMonitor fires on every minor path detail change (interface
                // list, gateway, etc.), not just real connectivity transitions.
                guard self.lastPathStatus != path.status else { return }
                self.lastPathStatus = path.status
                // A result launched on the old path must not be accepted after the
                // interface loses and regains a route, even if the SSID never
                // changes during that interval.
                self.networkGeneration &+= 1
                self.consecutiveOfflineProbes = 0
                self.offlineConfirmationWorkItem?.cancel()
                self.offlineConfirmationWorkItem = nil
                self.lastReachabilityCheck = nil
                if path.status != .satisfied {
                    AutoConnectManager.shared.cancelAutomaticLoginForReadinessLoss()
                }
                self.updateNetworkStatus()
                // Only chase a login when the OS believes there is a usable path.
                // This fired on every transition, including the transition *to*
                // .unsatisfied — so losing the network kicked off a portal login
                // against a link macOS had just declared dead, which fails
                // instantly with -1009 and burns a rung of the retry ladder for
                // nothing. The timers still cover the case where a path comes
                // back without a status change.
                guard path.status == .satisfied else {
                    Logger.shared.debug("Network path is \(path.status) — not probing.")
                    return
                }
                self.checkInternetIfNeeded()
            }
        }
        monitor.start(queue: pathQueue)
        pathMonitor = monitor
    }

    /// If we're on SRM Wi-Fi but have no real internet (session dropped without an
    /// SSID change), trigger a login. No-ops off SRM Wi-Fi, while an attempt is in
    /// flight, or while the manager is backing off.
    func checkInternetIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isReadyForAutomaticLogin else { return }
        guard !AutoConnectManager.shared.isConnecting else { return }
        guard !reachabilityProbeInFlight else { return }
        if let next = AutoConnectManager.shared.nextAttemptAt, next > Date() { return }

        if let last = lastReachabilityCheck, Date().timeIntervalSince(last) < reachabilityMinInterval {
            return
        }
        lastReachabilityCheck = Date()
        let generation = networkGeneration
        reachabilityProbeInFlight = true

        AutoConnectManager.shared.probeReachability(quiet: true) { [weak self] state in
            guard let self else { return }
            self.reachabilityProbeInFlight = false
            guard self.isReadyForAutomaticLogin, self.networkGeneration == generation else {
                Logger.shared.debug("Ignoring reachability result from a previous Wi-Fi network.")
                // If the path recovered while this old probe was still in flight,
                // the recovery-triggered check was coalesced by the in-flight
                // guard. Replace it now instead of waiting for the 15s timer (or a
                // stale 60s online throttle) to notice.
                if self.isReadyForAutomaticLogin {
                    self.lastReachabilityCheck = nil
                    DispatchQueue.main.async { [weak self] in self?.checkInternetIfNeeded() }
                }
                return
            }
            guard !state.online else {
                self.consecutiveOfflineProbes = 0
                self.offlineConfirmationWorkItem?.cancel()
                self.offlineConfirmationWorkItem = nil
                self.lastProbeWasOnline = true
                self.warnedAboutTunnel = false
                return
            }
            self.lastProbeWasOnline = false

            self.consecutiveOfflineProbes += 1
            if self.consecutiveOfflineProbes == 1 {
                Logger.shared.debug("Reachability failed once (\(state.detail)) — confirming before portal login.")
                self.scheduleOfflineConfirmation(for: generation)
                return
            }

            self.offlineConfirmationWorkItem?.cancel()
            self.offlineConfirmationWorkItem = nil
            // A VPN/tunnel interface (e.g. Cloudflare WARP) can stop captive-portal
            // traffic from ever reaching the local gateway. Say so once per outage
            // rather than on every failed poll.
            if !self.warnedAboutTunnel,
               let path = self.pathMonitor?.currentPath, path.usesInterfaceType(.other) {
                self.warnedAboutTunnel = true
                Logger.shared.log("A VPN/tunnel is active (e.g. Cloudflare WARP) — it can block captive portal login. Pause it if login keeps failing.")
            }
            Logger.shared.debug("On SRMIST with confirmed no internet — triggering login.")
            AutoConnectManager.shared.attemptLogin(afterConfirmedOutage: state)
        }
    }

    private func scheduleOfflineConfirmation(for generation: Int) {
        offlineConfirmationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.networkGeneration == generation,
                  self.isReadyForAutomaticLogin else { return }
            self.offlineConfirmationWorkItem = nil
            self.lastReachabilityCheck = nil
            self.checkInternetIfNeeded()
        }
        offlineConfirmationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + offlineConfirmationDelay, execute: work)
    }

    @objc private func handleWakeNotification() {
        // Waking usually delivers several of the observed notifications within a
        // moment of each other. Without this, each one would cancel the retry the
        // previous one had just re-armed, and they would stack up settle timers.
        if let last = lastWakeHandledAt, Date().timeIntervalSince(last) < 3 {
            Logger.shared.debug("Duplicate wake notification — already settling.")
            return
        }
        lastWakeHandledAt = Date()

        Logger.shared.debug("System woke from sleep. Rechecking network in 5s...")
        // A retry scheduled before sleep would otherwise fire the instant the run
        // loop resumes, before the interface has reassociated — guaranteeing an
        // extra failure. Let the 5s settle delay below drive the next attempt.
        AutoConnectManager.shared.cancelPendingRetryForWake()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self else { return }
            // Interfaces come back up unevenly after wake; don't let a stale
            // throttle from before sleep suppress the first real check.
            self.lastReachabilityCheck = nil
            self.updateNetworkStatus()
            self.checkInternetIfNeeded()
        }
    }

    func updateNetworkStatus() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.updateNetworkStatus() }
            return
        }
        let interface = client?.interface()
        if interface == nil {
            // CoreWLAN can briefly return no interface while Wi-Fi is being
            // disabled or reassociated. Treat that as an unusable observation so
            // no portal attempt is started against a stale retained SSID.
            Logger.shared.debug("No Wi-Fi interface available.")
        }
        let raw = interface?.ssid() ?? ""
        let observationWasUsable = latestSSIDReadWasUsable
        latestSSIDReadWasUsable = !raw.isEmpty
        if observationWasUsable != latestSSIDReadWasUsable {
            // Invalidate probes launched on the other side of this transition.
            // The retained display SSID may not change, but the network state that
            // owns an asynchronous result certainly did.
            networkGeneration &+= 1
            consecutiveOfflineProbes = 0
            offlineConfirmationWorkItem?.cancel()
            offlineConfirmationWorkItem = nil
            if !latestSSIDReadWasUsable {
                AutoConnectManager.shared.cancelAutomaticLoginForReadinessLoss()
            }
        }

        if raw.isEmpty {
            guard !currentSSID.isEmpty else { return }
            pendingEmptyReads += 1
            guard pendingEmptyReads >= emptyReadsToConfirm else {
                Logger.shared.debug("Transient empty SSID read (\(pendingEmptyReads)/\(emptyReadsToConfirm)) — holding '\(currentSSID)'.")
                return
            }
        }
        pendingEmptyReads = 0

        guard raw != currentSSID else {
            if !observationWasUsable && latestSSIDReadWasUsable {
                Logger.shared.debug("Wi-Fi observation recovered on '\(raw)' — rechecking connectivity.")
                lastReachabilityCheck = nil
                checkInternetIfNeeded()
            }
            return
        }

        let previous = currentSSID
        currentSSID = raw
        networkGeneration &+= 1
        consecutiveOfflineProbes = 0
        offlineConfirmationWorkItem?.cancel()
        offlineConfirmationWorkItem = nil
        let isSRM = NetworkMonitor.isSRMNetwork(raw)
        isConnectedToSRM = isSRM
        Logger.shared.log("Wi-Fi: \(previous.isEmpty ? "none" : previous) → \(raw.isEmpty ? "none" : raw)")

        if isSRM {
            // Joining is a genuine new-network event, so let it probe right away.
            lastReachabilityCheck = nil
            // Whatever we knew about the previous network says nothing about this
            // one; assume the worst so the probe runs on the tight interval until
            // it has actually confirmed we are online here.
            lastProbeWasOnline = false
            warnedAboutTunnel = false
            checkInternetIfNeeded()
        } else if NetworkMonitor.isSRMNetwork(previous) {
            // Do not let a retry or a WebKit navigation that began on SRMIST run
            // on the next network. This is a normal network transition, not an
            // authentication failure.
            AutoConnectManager.shared.cancelAutomaticLoginForNetworkChange()
        }
    }
}
