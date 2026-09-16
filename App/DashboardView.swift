import SwiftUI

struct DashboardView: View {
    @ObservedObject var autoConnect = AutoConnectManager.shared
    @ObservedObject var networkMonitor = NetworkMonitor.shared

    private func bannerTitle(_ result: AutoConnectManager.LoginResult) -> String {
        switch result {
        case .success: return "CONNECTED"
        case .alreadyOnline: return "ALREADY ONLINE"
        case .failure: return "LOGIN FAILED"
        }
    }

    var body: some View {
        // Force Connect is pinned below the scroll area rather than sitting at
        // the end of it. The popover is a fixed 300x400, and with the NEXT
        // ATTEMPT row, the CONNECTING spinner and the result banner all present
        // the content runs past 400pt — so the one button the user came here to
        // press was below the fold precisely when the app was failing and they
        // most wanted it.
        VStack(spacing: 0) {
        ScrollView {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("SRM AUTOCONNECT")
                    .font(Theme.mono(18, weight: .bold))
                    .foregroundColor(Theme.green)
                Spacer()

                Circle()
                    .fill(networkMonitor.isConnectedToSRM ? Theme.green : Color.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: networkMonitor.isConnectedToSRM ? Theme.green : Color.red, radius: 4)
            }
            .padding(.horizontal)
            .padding(.top, 26)
            
            // Metrics Cards
            HStack(spacing: 15) {
                MetricCard(
                    title: "Success",
                    value: "\(autoConnect.totalSuccesses)",
                    icon: "checkmark.circle.fill",
                    color: Theme.green
                )
                
                MetricCard(
                    title: "Failed",
                    value: "\(autoConnect.totalFailures)",
                    icon: "xmark.circle.fill",
                    color: .red
                )
            }
            .padding(.horizontal)
            
            // Status Info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("LAST CONNECTED:")
                        .foregroundColor(Theme.dimGreen)
                    Spacer()
                    if let last = autoConnect.lastConnectedTime {
                        Text(last, style: .time)
                            .foregroundColor(Theme.green)
                    } else {
                        Text("NEVER")
                            .foregroundColor(Theme.green)
                    }
                }
                .font(Theme.mono(13))

                HStack {
                    Text("CURRENT NETWORK:")
                        .foregroundColor(Theme.dimGreen)
                    Spacer()
                    Text(networkMonitor.currentSSID.isEmpty ? "None" : networkMonitor.currentSSID)
                        .foregroundColor(Theme.green)
                }
                .font(Theme.mono(13))

                // A deliberate backoff would otherwise look like the app has
                // silently stopped trying.
                if !autoConnect.isConnecting, let next = autoConnect.nextAttemptAt, next > Date() {
                    HStack {
                        Text("NEXT ATTEMPT:")
                            .foregroundColor(Theme.dimGreen)
                        Spacer()
                        Text(next, style: .relative)
                            .foregroundColor(Theme.amber)
                    }
                    .font(Theme.mono(13))
                }

                if autoConnect.isConnecting {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("CONNECTING...")
                            .foregroundColor(Theme.green)
                            .font(Theme.mono(13))
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
            .terminalPanel()
            .padding(.horizontal)

            // Last attempt's outcome — otherwise a login attempt resolves with nothing
            // visible once the spinner above disappears.
            if let result = autoConnect.lastResult {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: result == .failure ? "xmark.circle.fill" : "checkmark.circle.fill")
                        Text(bannerTitle(result))
                    }
                    .font(Theme.mono(12, weight: .semibold))
                    // The banner used to read "LOGIN FAILED — CHECK CREDENTIALS"
                    // for every failure, including the many that have nothing to
                    // do with credentials — portal unreachable, network not up
                    // yet, attempt timed out. Show the actual reason.
                    if result == .failure, let reason = autoConnect.lastFailureReason {
                        Text(reason.uppercased())
                            .font(Theme.mono(9))
                            .foregroundColor(.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundColor(result == .failure ? .red : Theme.green)
                .frame(maxWidth: .infinity)
                .padding(8)
                .terminalPanel(tint: result == .failure ? .red : Theme.green)
                .padding(.horizontal)
                .transition(.opacity)
            }

        }
        .animation(.easeOut(duration: 0.2), value: autoConnect.lastResult)
        .padding(.bottom, 12)
        }

        // Force Connect Button — outside the ScrollView, always reachable.
        Button(action: {
            autoConnect.attemptLogin(force: true)
        }) {
            Text(autoConnect.isConnecting ? "> CONNECTING... <" : "> FORCE CONNECT <")
                .font(Theme.mono(13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(autoConnect.isConnecting ? Theme.amber.opacity(0.45) : Theme.amber)
                .foregroundColor(.black)
                .cornerRadius(6)
                .shadow(color: Theme.amber.opacity(0.5), radius: 5, x: 0, y: 0)
        }
        .buttonStyle(PlainButtonStyle())
        // Pressing it mid-attempt was a completely silent no-op: startLogin()
        // returns early on `isConnecting`, so nothing on screen acknowledged the
        // click at all. Say so by disabling it instead.
        .disabled(autoConnect.isConnecting)
        .help(autoConnect.isConnecting ? "A login attempt is already running" : "Ignore the current backoff and try to log in now")
        .accessibilityLabel("Force connect")
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 14))

            Text(value)
                .font(Theme.mono(26, weight: .bold))
                .foregroundColor(Theme.green)

            Text(title.uppercased())
                .font(Theme.mono(11, weight: .medium))
                .foregroundColor(Theme.dimGreen)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .terminalPanel()
    }
}
