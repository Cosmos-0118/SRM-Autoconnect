import Foundation

/// Each run owns an independent batch. All decision state lives on main;
/// cancelled and late responses cannot resolve a batch a second time.
final class ReachabilityProbe {
    struct Result {
        let online: Bool
        let captivePortal: Bool
        let detail: String
    }
    private static let canaries: [(url: URL, expect: String)] = [
        (URL(string: "https://example.com")!, "Example Domain"),
        (URL(string: "https://cloudflare.com/cdn-cgi/trace")!, "fl="),
        (URL(string: "https://www.mozilla.org/robots.txt")!, "user-agent")
    ]
    private static let appleURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    private let injectedSession: URLSession?
    private let diagnostic: (String) -> Void

    init(session: URLSession? = nil, diagnostic: @escaping (String) -> Void = { _ in }) {
        self.injectedSession = session
        self.diagnostic = diagnostic
    }

    /// A brand-new session for every batch. One long-lived session kept HTTP/2
    /// connections to the canaries pooled (steady-state probes took ~0.03s, i.e.
    /// no handshake at all). A captive gateway's firewall typically keeps
    /// allowing flows that were already established, so a reused connection can
    /// keep answering "online" after the login has expired and every *new*
    /// connection — the browser's, the portal's — is already blocked. That is a
    /// false "online" which suppresses the login that would fix it. A fresh
    /// session guarantees fresh DNS + TCP + TLS each time.
    private func makeFreshSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpShouldUsePipelining = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }

    func run(completion: @escaping (Result) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.run(completion: completion) }
            return
        }
        let session = injectedSession ?? makeFreshSession()
        let batch = Batch(completion: completion)
        if injectedSession == nil { batch.ownedSession = session }
        let deadline = DispatchWorkItem { batch.finish(online: false) }
        batch.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        for canary in Self.canaries {
            start(canary.url, expect: canary.expect, batch: batch, session: session)
        }
        // Apple is a diagnostic, never a vote toward the ordinary-host quorum.
        start(Self.appleURL, expect: nil, batch: batch, session: session)
    }

    /// Unique query string defeats any transparent/intercepting cache between us
    /// and the canary; the request headers ask intermediaries not to answer from
    /// cache or keep the connection.
    private static func cacheBusted(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.queryItems ?? []
        items.append(URLQueryItem(name: "_srm", value: UUID().uuidString))
        parts.queryItems = items
        return parts.url ?? url
    }

    private func start(_ url: URL, expect: String?, batch: Batch, session: URLSession) {
        var request = URLRequest(url: Self.cacheBusted(url))
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let started = ProcessInfo.processInfo.systemUptime
        let task = session.dataTask(with: request) { [diagnostic] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            // A captive gateway answers with a redirect or its own page: the
            // final URL must still be the host we asked for.
            let sameHost = response?.url?.host?.lowercased() == url.host?.lowercased()
            let valid = error == nil && (200...299).contains(status) && sameHost
            let passed = valid && (expect.map { body?.range(of: $0, options: .caseInsensitive) != nil } ?? true)
            let intercepted = expect == nil && passed && !(body ?? "").contains("Success")
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            DispatchQueue.main.async {
                guard !batch.finished else { return }
                // Only fixed request hosts and numeric status/timing are logged.
                diagnostic("Probe host=\(url.host ?? "?") status=\(status) error=\((error as NSError?)?.code ?? 0) elapsed=\(String(format: "%.3f", elapsed))s valid=\(passed)")
                if expect != nil {
                    batch.pendingCanaries -= 1
                    if passed { batch.names.append(url.host ?? "?") }
                } else {
                    batch.appleFinished = true
                    batch.intercepted = intercepted
                }
                if batch.names.count >= 2 {
                    batch.finish(online: true)
                } else if batch.names.count + batch.pendingCanaries < 2 && batch.appleFinished {
                    batch.finish(online: false)
                }
            }
        }
        batch.tasks.append(task)
        task.resume()
    }

    private final class Batch {
        var tasks: [URLSessionDataTask] = []
        var names: [String] = []
        var pendingCanaries = 3
        var appleFinished = false
        var intercepted = false
        var finished = false
        var ownedSession: URLSession?
        var deadline: DispatchWorkItem?
        private var completion: ((Result) -> Void)?
        init(completion: @escaping (Result) -> Void) { self.completion = completion }

        func finish(online: Bool) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard !finished else { return }
            finished = true
            deadline?.cancel(); deadline = nil
            tasks.forEach { $0.cancel() }; tasks.removeAll()
            ownedSession?.invalidateAndCancel(); ownedSession = nil
            let detail = "\(names.count)/3 canaries ok\(names.isEmpty ? "" : " [\(names.joined(separator: ", "))]")\(intercepted && !online ? ", portal intercepting" : "")"
            let callback = completion; completion = nil
            callback?(Result(online: online, captivePortal: intercepted && !online, detail: detail))
        }
    }
}
