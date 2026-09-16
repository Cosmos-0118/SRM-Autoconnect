import Foundation
import CoreWLAN
import AppKit
import CoreLocation
import Network

final class NetworkMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = NetworkMonitor()

    @Published var currentSSID: String = ""
    @Published var isConnectedToSRM: Bool = false

    private let srmSSIDs: Set<String> = ["SRMIST"]

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

    /// Reachability is a real network fetch. The 15s timer and the path monitor can
    /// otherwise fire back to back and probe twice for one event.
    private var lastReachabilityCheck: Date?
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

    private override init() {
        super.init()
        self.client = CWWiFiClient.shared()

        // macOS 14+ requires location permission to read SSID
        if #available(macOS 14.0, *) {
            self.locationManager = CLLocationManager()
            self.locationManager?.delegate = self
            self.locationManager?.requestWhenInUseAuthorization()
        }

        setupNotifications()
        setupPathMonitor()
        updateNetworkStatus()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // Without this permission ssid() returns nil forever, which is
        // indistinguishable from "not on Wi-Fi" — worth saying out loud.
        if status == .denied || status == .restricted {
            Logger.shared.log("Location permission denied — macOS won't report the Wi-Fi name, so SRMIST can't be detected automatically.")
        } else {
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
                self.updateNetworkStatus()
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
        guard isConnectedToSRM else { return }
        guard !AutoConnectManager.shared.isConnecting else { return }
        if let next = AutoConnectManager.shared.nextAttemptAt, next > Date() { return }

        if let last = lastReachabilityCheck, Date().timeIntervalSince(last) < reachabilityMinInterval {
            return
        }
        lastReachabilityCheck = Date()
        let generation = networkGeneration

        AutoConnectManager.shared.probeInternet { [weak self] success in
            guard let self else { return }
            guard self.isConnectedToSRM, self.networkGeneration == generation else {
                Logger.shared.debug("Ignoring reachability result from a previous Wi-Fi network.")
                return
            }
            self.lastProbeWasOnline = success
            guard !success else {
                self.warnedAboutTunnel = false
                return
            }
            // A VPN/tunnel interface (e.g. Cloudflare WARP) can stop captive-portal
            // traffic from ever reaching the local gateway. Say so once per outage
            // rather than on every failed poll.
            if !self.warnedAboutTunnel,
               let path = self.pathMonitor?.currentPath, path.usesInterfaceType(.other) {
                self.warnedAboutTunnel = true
                Logger.shared.log("A VPN/tunnel is active (e.g. Cloudflare WARP) — it can block captive portal login. Pause it if login keeps failing.")
            }
            Logger.shared.debug("On SRMIST with no internet — triggering login.")
            AutoConnectManager.shared.attemptLogin()
        }
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
        guard let interface = client?.interface() else {
            Logger.shared.debug("No Wi-Fi interface available.")
            return
        }

        let raw = interface.ssid() ?? ""

        if raw.isEmpty {
            guard !currentSSID.isEmpty else { return }
            pendingEmptyReads += 1
            guard pendingEmptyReads >= emptyReadsToConfirm else {
                Logger.shared.debug("Transient empty SSID read (\(pendingEmptyReads)/\(emptyReadsToConfirm)) — holding '\(currentSSID)'.")
                return
            }
        }
        pendingEmptyReads = 0

        guard raw != currentSSID else { return }

        let previous = currentSSID
        currentSSID = raw
        networkGeneration &+= 1
        let isSRM = srmSSIDs.contains(raw)
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
        } else if srmSSIDs.contains(previous) {
            // Do not let a retry or a WebKit navigation that began on SRMIST run
            // on the next network. This is a normal network transition, not an
            // authentication failure.
            AutoConnectManager.shared.cancelAutomaticLoginForNetworkChange()
        }
    }
}
