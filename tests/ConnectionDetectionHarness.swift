import Foundation
import Network

// Only external login/credential effects are replaced; the real monitor and
// probe policy run against injected SSID, path, clock, and probe observations.
final class AutoConnectManager {
    typealias Reachability = ReachabilityProbe.Result
    static let shared = AutoConnectManager()
    var isConnecting = false
    var nextAttemptAt: Date?
    func probeReachability(quiet: Bool, completion: @escaping (Reachability) -> Void) {}
    func attemptLogin(afterConfirmedOutage: Reachability) {}
    func cancelAutomaticLoginForReadinessLoss() {}
    func cancelAutomaticLoginForNetworkChange() {}
    func cancelPendingRetryForWake() {}
}
final class Logger {
    static let shared = Logger()
    func log(_ message: String) {}
    func debug(_ message: String) {}
}
@main struct DetectionHarness {
    static var failures = 0
    static func check(_ name: String, _ condition: Bool) {
        print("[\(condition ? "PASS" : "FAIL")] \(name)"); if !condition { failures += 1 }
    }
    final class World {
        var ssid: String? = "SRMIST"
        var time: TimeInterval = 100
        var connecting = false
        var next: Date?
        var probes: [(ReachabilityProbe.Result) -> Void] = []
        var scheduled: [(Double, DispatchWorkItem)] = []
        var logins = 0
        var readinessCancellations = 0
        var networkCancellations = 0
        var wakeCancellations = 0
        func monitor() -> NetworkMonitor {
            NetworkMonitor(dependencies: .init(
                readSSID: { self.ssid }, now: { self.time },
                probe: { self.probes.append($0) }, isConnecting: { self.connecting }, nextAttemptAt: { self.next },
                login: { _ in self.logins += 1 }, cancelForReadiness: { self.readinessCancellations += 1 },
                cancelForNetworkChange: { self.networkCancellations += 1 }, cancelForWake: { self.wakeCancellations += 1 },
                schedule: { self.scheduled.append(($0, $1)) }))
        }
        func fireScheduled() {
            let pending = scheduled; scheduled.removeAll()
            for (_, item) in pending where !item.isCancelled { item.perform() }
        }
    }
    static func main() {
        let online = ReachabilityProbe.Result(online: true, captivePortal: false, detail: "2/3")
        let offline = ReachabilityProbe.Result(online: false, captivePortal: false, detail: "0/3")
        let captive = ReachabilityProbe.Result(online: false, captivePortal: true, detail: "intercepting")
        check("Apple cannot override online quorum", !ConnectionDetectionPolicy.shouldLogin(after: .init(online: true, captivePortal: true, detail: ""), consecutiveOfflineProbes: 2))
        check("ambiguous outage needs confirmation", !ConnectionDetectionPolicy.shouldLogin(after: offline, consecutiveOfflineProbes: 1))
        check("explicit interception can trigger now", ConnectionDetectionPolicy.shouldLogin(after: captive, consecutiveOfflineProbes: 1))
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            check("join launches single probe", w.probes.count == 1)
            w.probes[0](captive)
            check("first captive result logs in", w.logins == 1 && w.scheduled.isEmpty)
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            w.probes[0](offline); check("ambiguous first result waits", w.logins == 0)
            w.time += 3; w.fireScheduled(); w.probes[1](offline)
            check("second ambiguous result logs in", w.logins == 1)
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            w.probes[0](online); w.time += 15; m.checkInternetIfNeeded()
            check("session expiry checked by next 15s tick", w.probes.count == 2)
            if w.probes.count == 2 {
                w.probes[1](offline); w.time += 3; w.fireScheduled(); w.probes[2](online)
                w.time += 15; m.checkInternetIfNeeded(); w.probes[3](offline)
                check("online resets negative confirmation", w.logins == 0)
            }
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            w.ssid = "Home"; m.updateNetworkStatus(); w.probes[0](captive)
            check("old-network result cannot log in", w.logins == 0 && w.networkCancellations == 1)
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            m.updatePathStatus(.unsatisfied); m.updatePathStatus(.satisfied); w.probes[0](captive)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            check("recovery replaces stale in-flight probe", w.probes.count == 2 && w.logins == 0 && w.readinessCancellations >= 1)
            w.probes[1](captive); check("current recovery result accepted", w.logins == 1)
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            w.probes[0](online); w.ssid = nil; m.updateNetworkStatus(); m.checkInternetIfNeeded()
            check("nil SSID retains identity but prevents work", m.isConnectedToSRM && w.probes.count == 1)
            w.ssid = "SRMIST"; m.updateNetworkStatus()
            check("SSID recovery probes immediately", w.probes.count == 2)
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            w.probes[0](online); m.handleWakeNotification(); m.handleWakeNotification()
            check("warm wake probes now and coalesces duplicates", w.probes.count == 2 && w.wakeCancellations == 1 && w.scheduled.isEmpty)
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            m.handleWakeNotification()
            check("wake replaces unresolved pre-sleep probe immediately", w.probes.count == 2)
            w.probes[0](captive)
            m.checkInternetIfNeeded()
            check("old completion cannot clear current in-flight probe", w.probes.count == 2 && w.logins == 0)
            if w.probes.count == 2 {
                w.probes[1](online); w.time += 15; m.checkInternetIfNeeded()
                check("wake replacement completes normally", w.probes.count == 3)
            }
        }
        do {
            let w = World(); w.ssid = nil; let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.unsatisfied)
            m.handleWakeNotification(); m.handleWakeNotification()
            check("cold wake has one 5s fallback", w.scheduled.count == 1 && w.scheduled[0].0 == 5)
            w.ssid = "SRMIST"; m.updatePathStatus(.satisfied); w.fireScheduled()
            check("fallback cannot overlap recovery probe", w.probes.count == 1)
        }
        do {
            let w = World(); let m = w.monitor(); w.next = Date().addingTimeInterval(60)
            m.updateNetworkStatus(); m.updatePathStatus(.satisfied); m.checkInternetIfNeeded()
            check("cooldown respected", w.probes.isEmpty)
            w.next = nil; w.connecting = true; m.checkInternetIfNeeded()
            check("active login suppresses probing", w.probes.isEmpty)
        }
        do {
            let w = World(); let m = w.monitor(); m.updateNetworkStatus(); m.updatePathStatus(.satisfied)
            w.probes[0](online)
            for _ in 0..<240 {
                w.time += 15; m.checkInternetIfNeeded(); w.probes.last!(online)
            }
            check("healthy one-hour polling volume bounded", w.probes.count == 241 && w.logins == 0)
            print("Healthy steady-state volume: 240 batches/hour; up to 720 ordinary + 240 diagnostic requests/hour")
        }
        print("Detection failures: \(failures)"); exit(failures == 0 ? 0 : 1)
    }
}
