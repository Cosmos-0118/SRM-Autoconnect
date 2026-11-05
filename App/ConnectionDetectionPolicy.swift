import Foundation

enum ConnectionDetectionPolicy {
    static func minimumProbeInterval(lastProbeWasOnline: Bool) -> TimeInterval {
        lastProbeWasOnline ? 15 : 10
    }
    /// Transport-level failures to reach the portal: the Mac has no usable route
    /// yet (just joined Wi-Fi, just woke, DHCP/DNS still coming up). Logs show
    /// these clearing within seconds to ~2 minutes with internet returning on its
    /// own, so they are "network still settling", not a login failure. TLS errors
    /// (-120x, -2000) are deliberately excluded: they mean something is answering.
    static func isTransportFailure(domain: String, code: Int) -> Bool {
        guard domain == NSURLErrorDomain else { return false }
        switch code {
        case NSURLErrorTimedOut,                 // -1001
             NSURLErrorCannotFindHost,           // -1003
             NSURLErrorCannotConnectToHost,      // -1004
             NSURLErrorNetworkConnectionLost,    // -1005
             NSURLErrorDNSLookupFailed,          // -1006
             NSURLErrorNotConnectedToInternet,   // -1009
             NSURLErrorInternationalRoamingOff,  // -1018
             NSURLErrorDataNotAllowed:           // -1020
            return true
        default:
            return false
        }
    }

    static func shouldLogin(after state: ReachabilityProbe.Result, consecutiveOfflineProbes: Int) -> Bool {
        !state.online && (state.captivePortal || consecutiveOfflineProbes >= 2)
    }
}
