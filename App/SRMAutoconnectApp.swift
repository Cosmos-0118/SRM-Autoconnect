import SwiftUI
import AppKit
import Combine

@main
struct SRMAutoconnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // This app's entire UI is the popover built in AppDelegate; the Scene
        // exists only because `App` requires one. A `Settings` scene, though,
        // also installs a ⌘, key equivalent, so pressing it while the popover
        // had focus opened an empty 900x450 window and dismissed the popover —
        // the app's real Settings tab is *inside* that popover. Removing the
        // .appSettings command group takes the shortcut and its menu item away
        // and leaves the empty scene unreachable.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
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
    /// never ran. Another froze 3 minutes mid-login, straight through the final
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
            button.action = #selector(statusItemClicked(_:))
            // Right-click was simply dead, and Quit lives inside the popover's
            // Settings tab — so if the popover ever failed to open there was no
            // way to quit the app at all short of Activity Monitor.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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


    @objc func statusItemClicked(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let status = NetworkMonitor.shared.currentSSID.isEmpty
            ? "Not on Wi-Fi"
            : "Wi-Fi: \(NetworkMonitor.shared.currentSSID)"
        let statusItemEntry = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItemEntry.isEnabled = false
        menu.addItem(statusItemEntry)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open SRM Autoconnect", action: #selector(togglePopover(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Force Connect", action: #selector(forceConnect), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Log File in Finder", action: #selector(revealLogFile), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SRM Autoconnect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        // Attaching the menu to the status item would make it open on *left*
        // click too and suppress the popover entirely, so pop it manually and
        // detach immediately.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func forceConnect() {
        AutoConnectManager.shared.attemptLogin(force: true)
    }

    @objc private func revealLogFile() {
        let path = Logger.shared.logFilePath
        guard path != "(unavailable)" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
