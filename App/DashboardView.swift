import SwiftUI

struct DashboardView: View {
    @ObservedObject var autoConnect = AutoConnectManager.shared
    @ObservedObject var networkMonitor = NetworkMonitor.shared
    
    var body: some View {
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
                HStack(spacing: 6) {
                    Image(systemName: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(result == .success ? "CONNECTED" : "LOGIN FAILED — CHECK CREDENTIALS")
                }
                .font(Theme.mono(12, weight: .semibold))
                .foregroundColor(result == .success ? Theme.green : .red)
                .frame(maxWidth: .infinity)
                .padding(8)
                .terminalPanel(tint: result == .success ? Theme.green : .red)
                .padding(.horizontal)
                .transition(.opacity)
            }

            // Force Connect Button
            Button(action: {
                autoConnect.attemptLogin(force: true)
            }) {
                Text("> FORCE CONNECT <")
                    .font(Theme.mono(13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Theme.amber)
                    .foregroundColor(.black)
                    .cornerRadius(6)
                    .shadow(color: Theme.amber.opacity(0.5), radius: 5, x: 0, y: 0)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .animation(.easeOut(duration: 0.2), value: autoConnect.lastResult)
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
