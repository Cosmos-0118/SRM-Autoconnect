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
    private let session: URLSession
    private let diagnostic: (String) -> Void

    init(session: URLSession? = nil, diagnostic: @escaping (String) -> Void = { _ in }) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 8
            config.waitsForConnectivity = false
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
        self.diagnostic = diagnostic
    }

    func run(completion: @escaping (Result) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.run(completion: completion) }
            return
        }
        let batch = Batch(completion: completion)
        let deadline = DispatchWorkItem { batch.finish(online: false) }
        batch.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        for canary in Self.canaries {
            start(canary.url, expect: canary.expect, batch: batch)
        }
        // Apple is a diagnostic, never a vote toward the ordinary-host quorum.
        start(Self.appleURL, expect: nil, batch: batch)
    }

    private func start(_ url: URL, expect: String?, batch: Batch) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let started = ProcessInfo.processInfo.systemUptime
        let task = session.dataTask(with: request) { [diagnostic] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            let valid = error == nil && (200...299).contains(status)
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
        var deadline: DispatchWorkItem?
        private var completion: ((Result) -> Void)?
        init(completion: @escaping (Result) -> Void) { self.completion = completion }

        func finish(online: Bool) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard !finished else { return }
            finished = true
            deadline?.cancel(); deadline = nil
            tasks.forEach { $0.cancel() }; tasks.removeAll()
            let detail = "\(names.count)/3 canaries ok\(names.isEmpty ? "" : " [\(names.joined(separator: ", "))]")\(intercepted && !online ? ", portal intercepting" : "")"
            let callback = completion; completion = nil
            callback?(Result(online: online, captivePortal: intercepted && !online, detail: detail))
        }
    }
}
