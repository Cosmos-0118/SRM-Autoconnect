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

    /// Injectable system boundaries keep detection decisions independent of
    /// CoreWLAN, Keychain, and real portal traffic.
    struct Dependencies {
        var readSSID: () -> String?
        var now: () -> TimeInterval
        var probe: (@escaping (AutoConnectManager.Reachability) -> Void) -> Void
        var isConnecting: () -> Bool
        var nextAttemptAt: () -> Date?
        var login: (AutoConnectManager.Reachability) -> Void
        var cancelForReadiness: () -> Void
        var cancelForNetworkChange: () -> Void
        var cancelForWake: () -> Void
        var schedule: (TimeInterval, DispatchWorkItem) -> Void

        static var live: Dependencies {
            Dependencies(readSSID: { CWWiFiClient.shared().interface()?.ssid() },
                         now: { ProcessInfo.processInfo.systemUptime },
                         probe: { AutoConnectManager.shared.probeReachability(quiet: true, completion: $0) },
                         isConnecting: { AutoConnectManager.shared.isConnecting },
                         nextAttemptAt: { AutoConnectManager.shared.nextAttemptAt },
                         login: { AutoConnectManager.shared.attemptLogin(afterConfirmedOutage: $0) },
                         cancelForReadiness: { AutoConnectManager.shared.cancelAutomaticLoginForReadinessLoss() },
                         cancelForNetworkChange: { AutoConnectManager.shared.cancelAutomaticLoginForNetworkChange() },
                         cancelForWake: { AutoConnectManager.shared.cancelPendingRetryForWake() },
                         schedule: { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) })
        }
    }
    private let dependencies: Dependencies
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
    private var lastReachabilityCheck: TimeInterval?
    private var nextProbeID = 0
    private var activeProbeID: Int?
    private var consecutiveOfflineProbes = 0
    private var offlineConfirmationWorkItem: DispatchWorkItem?
    private let offlineConfirmationDelay: TimeInterval = 3
    private var reachabilityMinInterval: TimeInterval {
        ConnectionDetectionPolicy.minimumProbeInterval(lastProbeWasOnline: lastProbeWasOnline)
    }
    private var lastProbeWasOnline = false
    private var warnedAboutTunnel = false
    /// Coalesces the several wake/unlock notifications macOS delivers together.
    private var lastWakeHandledAt: TimeInterval?
    private var wakeRecheckWorkItem: DispatchWorkItem?

    /// Automatic attempts require both a retained SRM identity and evidence that
    /// the interface is usable right now. A force attempt intentionally bypasses
    /// this gate so the dashboard button remains a useful diagnostic escape hatch.
    var isReadyForAutomaticLogin: Bool {
        isConnectedToSRM
            && latestSSIDReadWasUsable
            && lastPathStatus == .satisfied
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        super.init()
    }

    private override init() {
        self.dependencies = .live
        super.init()

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
            DispatchQueue.main.async { self?.updatePathStatus(path.status) }
        }
        monitor.start(queue: pathQueue)
        pathMonitor = monitor
    }

    func updatePathStatus(_ status: NWPath.Status) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard lastPathStatus != status else { return }
        lastPathStatus = status
        networkGeneration &+= 1
        activeProbeID = nil
        consecutiveOfflineProbes = 0
        offlineConfirmationWorkItem?.cancel()
        offlineConfirmationWorkItem = nil
        lastReachabilityCheck = nil
        if status != .satisfied { dependencies.cancelForReadiness() }
        updateNetworkStatus()
        guard status == .satisfied else {
            Logger.shared.debug("Network path is \(status) — not probing.")
            return
        }
        checkInternetIfNeeded(reason: "path-change")
    }

    /// If we're on SRM Wi-Fi but have no real internet (session dropped without an
    /// SSID change), trigger a login. No-ops off SRM Wi-Fi, while an attempt is in
    /// flight, or while the manager is backing off.
    func checkInternetIfNeeded(reason: String = "timer") {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isReadyForAutomaticLogin else { return }
        guard !dependencies.isConnecting() else { return }
        guard activeProbeID == nil else { return }
        if let next = dependencies.nextAttemptAt(), next > Date() { return }

        if let last = lastReachabilityCheck, dependencies.now() - last < reachabilityMinInterval {
            return
        }
        lastReachabilityCheck = dependencies.now()
        let generation = networkGeneration
        nextProbeID &+= 1
        let probeID = nextProbeID
        activeProbeID = probeID
        let started = dependencies.now()
        Logger.shared.debug("Detection generation=\(generation) trigger=\(reason) probe started")

        dependencies.probe { [weak self] state in
            guard let self else { return }
            // A previous epoch may finish after its replacement started. Only
            // the current probe may release the in-flight gate or update state.
            guard self.activeProbeID == probeID else {
                Logger.shared.debug("Ignoring superseded probe id=\(probeID) generation=\(generation)")
                return
            }
            self.activeProbeID = nil
            Logger.shared.debug("Detection generation=\(generation) probe elapsed=\(String(format: "%.3f", self.dependencies.now() - started))s online=\(state.online)")
            guard self.isReadyForAutomaticLogin, self.networkGeneration == generation else {
                Logger.shared.debug("Ignoring reachability result from a previous Wi-Fi network.")
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
            if !ConnectionDetectionPolicy.shouldLogin(after: state, consecutiveOfflineProbes: self.consecutiveOfflineProbes) {
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
            self.dependencies.login(state)
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
            self.checkInternetIfNeeded(reason: "outage-confirmation")
        }
        offlineConfirmationWorkItem = work
        dependencies.schedule(offlineConfirmationDelay, work)
    }

    @objc func handleWakeNotification() {
        // Waking usually delivers several of the observed notifications within a
        // moment of each other. Without this, each one would cancel the retry the
        // previous one had just re-armed, and they would stack up settle timers.
        if let last = lastWakeHandledAt, dependencies.now() - last < 3 {
            Logger.shared.debug("Duplicate wake notification — already settling.")
            return
        }
        lastWakeHandledAt = dependencies.now()

        // Wake invalidates observations even if SSID and path text stay the same.
        dependencies.cancelForWake()
        networkGeneration &+= 1
        activeProbeID = nil
        consecutiveOfflineProbes = 0
        offlineConfirmationWorkItem?.cancel()
        offlineConfirmationWorkItem = nil
        wakeRecheckWorkItem?.cancel()
        wakeRecheckWorkItem = nil
        lastReachabilityCheck = nil
        updateNetworkStatus()
        if isReadyForAutomaticLogin {
            Logger.shared.debug("System woke — network ready; checking now.")
            checkInternetIfNeeded(reason: "wake-ready")
            return
        }
        Logger.shared.debug("System woke — waiting for network; fallback check in 5s.")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeRecheckWorkItem = nil
            self.lastReachabilityCheck = nil
            self.updateNetworkStatus()
            self.checkInternetIfNeeded(reason: "wake-fallback")
        }
        wakeRecheckWorkItem = work
        dependencies.schedule(5, work)
    }

    func updateNetworkStatus() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.updateNetworkStatus() }
            return
        }
        let raw = dependencies.readSSID() ?? ""
        let observationWasUsable = latestSSIDReadWasUsable
        latestSSIDReadWasUsable = !raw.isEmpty
        if observationWasUsable != latestSSIDReadWasUsable {
            // Invalidate probes launched on the other side of this transition.
            // The retained display SSID may not change, but the network state that
            // owns an asynchronous result certainly did.
            networkGeneration &+= 1
            activeProbeID = nil
            consecutiveOfflineProbes = 0
            offlineConfirmationWorkItem?.cancel()
            offlineConfirmationWorkItem = nil
            if !latestSSIDReadWasUsable {
                dependencies.cancelForReadiness()
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
                checkInternetIfNeeded(reason: "ssid-recovery")
            }
            return
        }

        let previous = currentSSID
        currentSSID = raw
        networkGeneration &+= 1
        activeProbeID = nil
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
            checkInternetIfNeeded(reason: "ssid-join")
        } else if NetworkMonitor.isSRMNetwork(previous) {
            // Do not let a retry or a WebKit navigation that began on SRMIST run
            // on the next network. This is a normal network transition, not an
            // authentication failure.
            dependencies.cancelForNetworkChange()
        }
    }
}
