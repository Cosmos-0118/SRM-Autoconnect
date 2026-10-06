import Foundation

// Generated Subject uses the exact production message dispatcher, verification,
// token guards, scheduling, finish, and URL redaction. External probes and WebKit
// message containers are local stand-ins; no Keychain reads or portal loads occur.
final class Logger {
    static let shared = Logger()
    var messages: [String] = []
    func debug(_ s: String) { messages.append(s) }
}
final class WKUserContentController {}
final class WKScriptMessage { let body: Any; init(_ body: Any) { self.body = body } }
final class StubWebView { func stopLoading() {} }
final class Subject {
    typealias Reachability = ReachabilityProbe.Result
    enum AttemptPhase { case idle, preflight, loadingPortal, waitingForLoginForm, waitingForPortalHandler, verifying }
    var currentAttempt = 1
    var isConnecting = true
    var attemptPhase: AttemptPhase = .waitingForLoginForm
    var loginSubmittedForAttempt = -1
    var navigationAttempts: [ObjectIdentifier: Int] = [:]
    var activePortalNavigation: ObjectIdentifier?
    var webView = StubWebView()
    var probes: [(Reachability) -> Void] = []
    var successes = 0
    var failures: [String] = []
    var loginFormTimeout: TimeInterval = 0.03
    var phaseStartedAt = ProcessInfo.processInfo.systemUptime
    var attemptStartedAt = ProcessInfo.processInfo.systemUptime
    func probeReachability(quiet: Bool, completion: @escaping (Reachability) -> Void) { probes.append(completion) }
    func succeed(_ token: Int) { successes += 1; finish(token) }
    func fail(_ token: Int, _ reason: String) { failures.append(reason); finish(token) }
    func send(_ stage: String, token: Int = 1) {
        userContentController(WKUserContentController(), didReceive: WKScriptMessage(["attempt": token, "stage": stage, "detail": "handler"]))
    }
    func cancel() { finish(currentAttempt) }
    func redact(_ url: URL) -> String { redacted(url) }
    func armFormWatchdog() {
        let token = currentAttempt
        // __FORM_WATCHDOG__
    }
    // __PRODUCTION_METHODS__
}
@main struct VerificationHarness {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) {
        print("[\(ok ? "PASS" : "FAIL")] \(name)"); if !ok { failures += 1 }
    }
    static func main() {
        let online = ReachabilityProbe.Result(online: true, captivePortal: false, detail: "2/3")
        let offline = ReachabilityProbe.Result(online: false, captivePortal: false, detail: "0/3")
        do {
            let s = Subject(); s.send("submitted")
            check("verification starts immediately", s.probes.count == 1)
            s.send("submitted")
            check("duplicate dispatch does not double verification", s.probes.count == 1)
            if let probe = s.probes.first { probe(online) }
            check("quorum resolves success once", s.successes == 1 && !s.isConnecting)
        }
        do {
            let s = Subject(); s.send("submitted")
            s.probes.first?(offline)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check("negative result keeps retry spacing", s.probes.count == 1 && s.failures.isEmpty)
            RunLoop.main.run(until: Date().addingTimeInterval(3.1))
            check("negative result retries after 3s", s.probes.count == 2)
            s.probes.last?(online); check("later opening succeeds", s.successes == 1)
        }
        do {
            let s = Subject(); s.send("submitted"); s.cancel(); s.probes.first?(online)
            check("late result after cancellation ignored", s.successes == 0 && s.failures.isEmpty)
            s.send("submitted", token: 1); check("old message ignored", s.probes.count == 1)
        }
        do {
            let s = Subject(); s.send("submitted"); s.probes.first?(offline); s.cancel()
            RunLoop.main.run(until: Date().addingTimeInterval(3.1))
            check("cancelled delayed verification ignored", s.probes.count == 1 && s.failures.isEmpty)
        }
        do {
            let s = Subject(); s.send("submiterror")
            check("handler error never enters verification", s.probes.isEmpty && s.failures.count == 1)
            let url = URL(string: "https://AN1234:s3cr3t@iac.srmist.edu.in/Connect/PortalMain?secret=s3cr3t#AN1234")!
            let text = s.redact(url)
            check("URL diagnostics redact secrets", !text.contains("AN1234") && !text.contains("s3cr3t") && !text.contains("?secret"))
        }
        do {
            let s = Subject(); s.send("waitinghandler"); s.armFormWatchdog()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check("native watchdog bounds suspended handler discovery", s.failures.count == 1 && s.failures[0].contains("portal authentication"))
        }
        do {
            let s = Subject(); s.armFormWatchdog(); s.cancel()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check("cancelled form watchdog cannot fail new attempt", s.failures.isEmpty)
        }
        do {
            let s = Subject(); s.send("submitted")
            let captive = ReachabilityProbe.Result(online: false, captivePortal: true, detail: "intercepting")
            for index in 0..<5 {
                s.probes.last?(captive)
                if index < 4 { RunLoop.main.run(until: Date().addingTimeInterval(3.1)) }
            }
            check("rejected login bounded to five verification checks", s.probes.count == 5 && s.failures.count == 1 && s.successes == 0 && !s.isConnecting)
        }
        print("Verification failures: \(failures)"); exit(failures == 0 ? 0 : 1)
    }
}
