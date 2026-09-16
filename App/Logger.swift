import Foundation

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let message: String
    var repeatCount: Int = 1

    var text: String {
        let stamp = Logger.stampFormatter.string(from: date)
        return repeatCount > 1 ? "[\(stamp)] \(message) (×\(repeatCount))" : "[\(stamp)] \(message)"
    }
}

final class Logger: ObservableObject {
    static let shared = Logger()

    @Published private(set) var logs: [LogEntry] = []

    /// Debug lines never enter the in-app log. The passive reachability poll alone
    /// emits hundreds of lines an hour; when those shared the `maxEntries` ring
    /// buffer with real events, every line explaining a failure was evicted within
    /// minutes. They still go to the log file, which is where post-mortems belong.
    var debugEnabled = false

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private let maxEntries = 300
    private let fileQueue = DispatchQueue(label: "com.srm.autoconnect.logfile")
    private let fileURL: URL?
    private let maxFileBytes: UInt64 = 1_000_000

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("SRMAutoconnect.log")
        } else {
            fileURL = nil
        }
    }

    /// User-facing event. Shows in the popover's log tab.
    func log(_ message: String) { emit(message, toUI: true) }

    /// Clears the in-app list only. The file log is the post-mortem record and
    /// deliberately survives, so clearing the view can never destroy the
    /// evidence someone is about to be asked for.
    func clearUILogs() {
        if Thread.isMainThread {
            logs.removeAll()
        } else {
            DispatchQueue.main.async { self.logs.removeAll() }
        }
    }

    /// Diagnostic detail. File and stdout only, unless `debugEnabled`.
    func debug(_ message: String) { emit(message, toUI: debugEnabled) }

    var logFilePath: String { fileURL?.path ?? "(unavailable)" }

    private func emit(_ message: String, toUI: Bool) {
        let now = Date()
        writeToFile("[\(Logger.fileFormatter.string(from: now))] \(message)")
        print(message)
        guard toUI else { return }

        DispatchQueue.main.async {
            // Collapse consecutive identical messages into a counter instead of
            // letting a repeating condition flush the whole buffer.
            if var top = self.logs.first, top.message == message {
                top.repeatCount += 1
                self.logs[0] = top
                return
            }
            self.logs.insert(LogEntry(date: now, message: message), at: 0)
            if self.logs.count > self.maxEntries {
                self.logs.removeLast(self.logs.count - self.maxEntries)
            }
        }
    }

    private func writeToFile(_ line: String) {
        guard let fileURL else { return }
        fileQueue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
               size > self.maxFileBytes {
                // Single-generation rotation; the previous run's tail stays available.
                try? fm.removeItem(at: fileURL.appendingPathExtension("1"))
                try? fm.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
