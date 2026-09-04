import SwiftUI
import AppKit

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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize singletons to start monitoring
        _ = NetworkMonitor.shared
        _ = AutoConnectManager.shared
        NotificationManager.shared.requestAuthorization()
        
        // Create the popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
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
            button.image = NSImage(systemSymbolName: "wifi.circle", accessibilityDescription: "SRM Autoconnect")
            button.action = #selector(togglePopover(_:))
        }
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
