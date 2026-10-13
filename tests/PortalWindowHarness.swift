import AppKit
import Foundation

// Test boundaries replace campus networking, Keychain and notifications only.
// The generated manager, its window, navigation, injection and lifecycle are real.
final class Logger {
    static let shared = Logger()
    var logFilePath = "(test)"
    func debug(_ text: String) { print(text) }
    func log(_ text: String) { print(text) }
}
final class KeychainHelper {
    static let shared = KeychainHelper()
    struct KeychainFailure: LocalizedError {
        let status: Int32
        var errorDescription: String? { "test failure" }
    }
    static func hint(for status: Int32) -> String { "test hint" }
    func read(service: String, account: String) throws -> Data? {
        Data((account == "username" ? "AN1234" : "s3cr3t").utf8)
    }
}
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    var currentSSID = "SRMIST"
    var isReadyForAutomaticLogin = true
    var isConnectedToSRM = true
    static func isSRMNetwork(_ ssid: String) -> Bool { ssid == "SRMIST" }
}
final class NotificationManager {
    static let shared = NotificationManager()
    func showConnectedToast() {}
}
final class ReachabilityProbe {
    struct Result { let online: Bool; let captivePortal: Bool; let detail: String }
    static var pending: [(Result) -> Void] = []
    init(diagnostic: @escaping (String) -> Void) {}
    func run(completion: @escaping (Result) -> Void) { Self.pending.append(completion) }
}
final class PortalWindowHarness: NSObject, NSApplicationDelegate {
    var activity: NSObjectProtocol?
    var manager: AutoConnectManager!
    var stage = 0
    var timer: Timer?
    var checks = 0
    let fixtureDir = CommandLine.arguments[1]
    let offline = ReachabilityProbe.Result(online: false, captivePortal: true, detail: "test offline")
    func check(_ text: String, _ ok: Bool) {
        print("[\(ok ? "PASS" : "FAIL")] \(text)")
        if !ok { exit(1) }
        checks += 1
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Portal window regression")
        manager = AutoConnectManager.shared
        check("no on-screen portal window while idle", !manager.portalWindowForTest.isVisible || !NSScreen.screens.contains { $0.visibleFrame.intersects(manager.portalWindowForTest.frame) })
        manager.attemptLogin(afterConfirmedOutage: offline)
        let window = manager.portalWindowForTest
        check("portal window visible during login", window.isVisible)
        check("portal window on screen and readable", NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) } && window.frame.width >= 400 && window.frame.height >= 400)
        check("portal window can be dismissed", window.styleMask.contains(.closable))
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { self.check("harness completed before deadline", false) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.advance() }
    }
    func advance() {
        switch stage {
        case 0:
            guard !ReachabilityProbe.pending.isEmpty else { return }
            check("delayed form and handler reached verification", manager.isConnecting)
            stage = 1
            // Hold verification briefly to capture the actual window for inspection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let view = self.manager.portalWindowForTest.contentView!
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]), CommandLine.arguments.count > 2 {
                        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                    }
                }
                let cookie = HTTPCookie(properties: [.domain: "iac.srmist.edu.in", .path: "/", .name: "old-session", .value: "test-only"] )!
                self.manager.portalBrowserForTest.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    ReachabilityProbe.pending.removeFirst()(.init(online: true, captivePortal: false, detail: "test quorum"))
                }
            }
        case 1:
            guard !manager.isConnecting else { return }
            check("success closes portal window", !manager.portalWindowForTest.isVisible && manager.lastResult == .success)
            stage = 2
            manager.attemptLogin(afterConfirmedOutage: offline)
            check("later login reopens portal window", manager.portalWindowForTest.isVisible)
            manager.portalBrowserForTest.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                self.check("new attempt discards stale portal cookies", !cookies.contains { $0.name == "old-session" })
            }
            let failures = manager.totalFailures
            manager.portalWindowForTest.performClose(nil)
            check("closing window cancels attempt without failure", !manager.isConnecting && !manager.portalWindowForTest.isVisible && manager.totalFailures == failures)
            check("closing window pauses automatic popup retries", (manager.nextAttemptAt?.timeIntervalSinceNow ?? 0) > 50)
            manager.attemptLogin(afterConfirmedOutage: offline)
            check("automatic trigger respects dismissal", !manager.isConnecting && !manager.portalWindowForTest.isVisible)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.check("cancelled page cannot start verification", ReachabilityProbe.pending.isEmpty)
                try! FileManager.default.copyItem(atPath: self.fixtureDir + "/missing.html", toPath: self.fixtureDir + "/missing-copy.html")
                try! FileManager.default.removeItem(atPath: self.fixtureDir + "/portal.html")
                try! FileManager.default.moveItem(atPath: self.fixtureDir + "/missing-copy.html", toPath: self.fixtureDir + "/portal.html")
                self.manager.attemptLogin(force: true)
                self.check("force connect starts after dismissal", self.manager.isConnecting)
                ReachabilityProbe.pending.removeFirst()(self.offline)
                self.check("force connect shows portal window", self.manager.portalWindowForTest.isVisible)
                self.stage = 3
            }
        case 3:
            guard !manager.isConnecting else { return }
            check("failed readiness closes portal window", !manager.portalWindowForTest.isVisible && manager.totalFailures == 1)
            check("missing handler failure stays specific", manager.lastFailureReason?.contains("authentication") == true)
            try! FileManager.default.removeItem(atPath: fixtureDir + "/portal.html")
            try! FileManager.default.copyItem(atPath: fixtureDir + "/redirect.html", toPath: fixtureDir + "/portal.html")
            manager.attemptLogin(force: true)
            ReachabilityProbe.pending.removeFirst()(offline)
            stage = 4
        case 4:
            guard manager.portalBrowserForTest.url?.lastPathComponent == "untrusted.html",
                  !manager.portalBrowserForTest.isLoading else { return }
            check("untrusted redirect never revealed in secure window", manager.portalBrowserForTest.isHidden)
            check("post-submit redirect retains verification", manager.isConnecting && ReachabilityProbe.pending.count == 1)
            ReachabilityProbe.pending.removeFirst()(.init(online: true, captivePortal: false, detail: "test quorum"))
            check("post-submit verification closes window", !manager.isConnecting && !manager.portalWindowForTest.isVisible)
            try! FileManager.default.removeItem(atPath: fixtureDir + "/portal.html")
            try! FileManager.default.copyItem(atPath: fixtureDir + "/granted.html", toPath: fixtureDir + "/portal.html")
            manager.attemptLogin(afterConfirmedOutage: offline)
            stage = 5
        case 5:
            guard !ReachabilityProbe.pending.isEmpty else { return }
            check("access-granted page enters connectivity verification", manager.portalStatus.contains("connected"))
            ReachabilityProbe.pending.removeFirst()(offline)
            if !manager.isConnecting {
                check("accepted session without internet closes window", !manager.portalWindowForTest.isVisible && manager.lastResult == .failure)
                check("accepted session failure does not blame credentials", manager.lastFailureReason?.contains("access") == true && manager.lastFailureReason?.contains("credentials") == false)
                print("ALL PASS: \(checks) portal window checks")
                exit(0)
            }
        default: break
        }
    }
}
@main struct PortalWindowTest {
    static func main() {
        let app = NSApplication.shared
        let harness = PortalWindowHarness()
        app.delegate = harness
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
