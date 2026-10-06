import Foundation

enum ConnectionDetectionPolicy {
    static func minimumProbeInterval(lastProbeWasOnline: Bool) -> TimeInterval {
        lastProbeWasOnline ? 15 : 10
    }
    static func shouldLogin(after state: ReachabilityProbe.Result, consecutiveOfflineProbes: Int) -> Bool {
        !state.online && (state.captivePortal || consecutiveOfflineProbes >= 2)
    }
}
