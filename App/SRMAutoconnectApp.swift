import SwiftUI
import AppKit
import Combine

@main
struct SRMAutoconnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    /// Keeps macOS from App Napping us. A background LSUIElement app with no
    /// visible window is prime App Nap material, and App Nap coalesces
    /// main-runloop timers and `asyncAfter` retries into buckets minutes wide.
    /// Measured over a real 20-hour run of this app: the 5s SSID poll and 15s
    /// reachability poll were stalled for 80% of wall-clock time, in a
    /// characteristic ~316s cadence. The damage is not cosmetic — one stall
    /// began immediately after "On SRMIST with no internet — triggering login"
    /// and lasted 33 minutes, so the reconnect the user was waiting for simply
    /// never ran. Another froze 3 minutes mid-login, straight through the 45s
    /// watchdog (which is itself an `asyncAfter`, so it stalled too).
    ///
    /// `.userInitiatedAllowingIdleSystemSleep` is the specific option that
    /// disables App Nap while still letting the Mac sleep normally. Plain
    /// `.userInitiated` also sets `idleSystemSleepDisabled`, which would hold
    /// the machine awake forever — a battery disaster for a menu-bar utility.
    private var activityToken: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Monitoring the SRMIST Wi-Fi captive portal"
        )

        // Initialize singletons to start monitoring
        _ = NetworkMonitor.shared
        _ = AutoConnectManager.shared
        NotificationManager.shared.requestAuthorization()
        
        // Create the popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        // The content is a hardcoded black terminal theme, but the popover frame
        // and its arrow are drawn by AppKit in the *system* appearance. On a Mac
        // in Light Mode that produced a pale grey arrow and pale corners stuck to
        // a pure-black panel. Pin the whole popover dark so its chrome matches
        // the only theme this UI has.
        popover.appearance = NSAppearance(named: .darkAqua)
        let hostingController = NSHostingController(rootView: MainMenuView())
        // MainMenuView is a fixed 300x400, so nothing about its intrinsic size
        // ever changes — disable auto-tracking so the popover never recomputes
        // or animates a resize on open or on tab switch.
        hostingController.sizingOptions = []
        popover.contentViewController = hostingController
        self.popover = popover
        
        // Create the status item
        self.statusItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))
        
        if let button = self.statusItem.button {
            button.action = #selector(togglePopover(_:))
            // Without an explicit target this relies on nil-target dispatch
            // finding the app delegate at the end of the responder chain. That
            // does work, but it also means any responder ahead of us that
            // happens to implement togglePopover(_:) would silently swallow the
            // click. Name the target instead.
            button.target = self
        }
        updateStatusIcon()

        // The menu-bar icon is this app's primary surface — most of the time it
        // is the *only* thing the user sees of it. It was a fixed "wifi.circle"
        // that looked identical whether the app was connected, mid-login,
        // failing, or off SRMIST entirely, so the one glanceable status
        // indicator the app had reported nothing at all.
        Publishers.CombineLatest3(
            NetworkMonitor.shared.$isConnectedToSRM,
            AutoConnectManager.shared.$isConnecting,
            AutoConnectManager.shared.$lastResult
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in self?.updateStatusIcon() }
        .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let description: String
        if AutoConnectManager.shared.isConnecting {
            symbol = "arrow.triangle.2.circlepath"
            description = "SRM Autoconnect — logging in"
        } else if AutoConnectManager.shared.lastResult == .failure {
            symbol = "wifi.exclamationmark"
            description = "SRM Autoconnect — login failed"
        } else if NetworkMonitor.shared.isConnectedToSRM {
            symbol = "wifi"
            description = "SRM Autoconnect — on SRMIST"
        } else {
            symbol = "wifi.slash"
            description = "SRM Autoconnect — not on SRMIST"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        // Template images follow the menu bar's own light/dark appearance and
        // tint correctly when the item is highlighted.
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }


    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = self.statusItem.button {
            if self.popover.isShown {
                self.popover.performClose(sender)
            } else {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            }
        }
    }
}
