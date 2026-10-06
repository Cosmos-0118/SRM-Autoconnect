import Foundation

final class FixtureProtocol: URLProtocol {
    struct Reply { let delay: Double; let status: Int; let body: String }
    static let lock = NSLock()
    static var replies: [String: Reply] = [:]
    static var cancellations = 0
    static var cancelledHosts: Set<String> = []
    var work: DispatchWorkItem?
    var completed = false
    let stateLock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let reply = Self.replies[request.url!.host!]!; Self.lock.unlock()
        let item = DispatchWorkItem { [self] in
            stateLock.lock(); completed = true; stateLock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: item)
    }
    override func stopLoading() {
        work?.cancel(); work = nil
        stateLock.lock(); let wasPending = !completed; stateLock.unlock()
        Self.lock.lock()
        Self.cancellations += 1
        if wasPending { Self.cancelledHosts.insert(request.url!.host!) }
        Self.lock.unlock()
    }
}
@main struct ReachabilityHarness {
    static var failures = 0
    static let hosts = ["example.com", "cloudflare.com", "www.mozilla.org", "captive.apple.com"]
    static let good = ["Example Domain", "fl=1", "USER-AGENT: *", "Success"]
    static func check(_ name: String, _ condition: Bool) {
        print("[\(condition ? "PASS" : "FAIL")] \(name)"); if !condition { failures += 1 }
    }
    static func main() {
        DispatchQueue.main.async { run(0) }
        RunLoop.main.run()
    }
    static func run(_ index: Int) {
        if index == 5 { runOverlapping(); return }
        var replies = zip(hosts, good).reduce(into: [String: FixtureProtocol.Reply]()) {
            $0[$1.0] = .init(delay: 0.03, status: 200, body: $1.1)
        }
        switch index {
        case 0: // Two successes must not wait for other requests.
            replies[hosts[2]] = .init(delay: 2, status: 200, body: good[2])
            replies[hosts[3]] = .init(delay: 2, status: 200, body: good[3])
        case 1: // Apple cannot turn one ordinary success into a quorum.
            replies[hosts[1]] = .init(delay: 0.03, status: 403, body: good[1])
            replies[hosts[2]] = .init(delay: 0.03, status: 200, body: "wrong body")
        case 2: // Interception is diagnostic, never evidence of online.
            replies[hosts[0]] = .init(delay: 0.03, status: 503, body: good[0])
            replies[hosts[1]] = .init(delay: 0.03, status: 200, body: "wrong body")
            replies[hosts[3]] = .init(delay: 0.03, status: 200, body: "Sign in to campus")
        case 3: // Quorum tolerates one bad host and case changes.
            replies[hosts[0]] = .init(delay: 0.03, status: 200, body: "wrong body")
        default: // A stalled diagnostic must still be bounded.
            for h in hosts.prefix(3) { replies[h] = .init(delay: 0.03, status: 503, body: "blocked") }
            replies[hosts[3]] = .init(delay: 20, status: 200, body: good[3])
        }
        FixtureProtocol.lock.lock(); FixtureProtocol.replies = replies; FixtureProtocol.cancellations = 0; FixtureProtocol.cancelledHosts = []; FixtureProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        let probe = ReachabilityProbe(session: session)
        let start = ProcessInfo.processInfo.systemUptime
        var calls = 0
        probe.run { result in
            calls += 1
            check("completion on main", Thread.isMainThread)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            switch index {
            case 0: check("early quorum", result.online && elapsed < 0.5)
            case 1: check("Apple alone insufficient", !result.online && !result.captivePortal)
            case 2: check("captivity classified", !result.online && result.captivePortal)
            case 3: check("independent-host tolerance", result.online)
            default: check("bounded offline result", !result.online && elapsed < 9)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                check("exactly one completion", calls == 1)
                if index == 0 {
                    FixtureProtocol.lock.lock(); let cancelled = FixtureProtocol.cancelledHosts; FixtureProtocol.lock.unlock()
                    check("unfinished tasks cancelled", cancelled.contains(hosts[2]) && cancelled.contains(hosts[3]))
                }
                session.invalidateAndCancel()
                withExtendedLifetime(probe) {}
                run(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if calls == 0 { print("FAIL: missing bounded completion"); exit(1) }
        }
    }
    static func runOverlapping() {
        FixtureProtocol.lock.lock()
        FixtureProtocol.replies = zip(hosts, good).reduce(into: [:]) { $0[$1.0] = .init(delay: 0.03, status: 200, body: $1.1) }
        FixtureProtocol.replies[hosts[2]] = .init(delay: 2, status: 200, body: good[2])
        FixtureProtocol.replies[hosts[3]] = .init(delay: 2, status: 200, body: good[3])
        FixtureProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        let probe = ReachabilityProbe(session: session)
        var results: [ReachabilityProbe.Result] = []
        let completion: (ReachabilityProbe.Result) -> Void = { result in
            results.append(result)
            if results.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    check("overlapping batches resolve independently once", results.count == 2 && results.allSatisfy { $0.online && $0.detail.hasPrefix("2/3") })
                    session.invalidateAndCancel(); withExtendedLifetime(probe) {}
                    print("Reachability failures: \(failures)"); exit(failures == 0 ? 0 : 1)
                }
            }
        }
        probe.run(completion: completion); probe.run(completion: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("FAIL: overlapping batches stalled"); exit(1) }
    }

}
