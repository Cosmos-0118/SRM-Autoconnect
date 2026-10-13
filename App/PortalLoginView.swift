import SwiftUI
import WebKit

/// The portal remains a visible, real WebKit view. Decoration lives outside it
/// so it cannot interfere with SRM's form, events or authentication scripts.
struct PortalLoginView: View {
    @ObservedObject var manager: AutoConnectManager
    let webView: WKWebView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let glowColors: [Color] = [
        Color(red: 0.35, green: 0.72, blue: 1),
        Color(red: 0.58, green: 0.43, blue: 1),
        Color(red: 1, green: 0.42, blue: 0.66),
        Color(red: 1, green: 0.73, blue: 0.48),
        Color(red: 0.35, green: 0.72, blue: 1)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !manager.isConnecting)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let gradient = AngularGradient(colors: glowColors, center: .center,
                                           angle: .degrees(time.truncatingRemainder(dividingBy: 12) * 30))
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(gradient).blur(radius: 12).opacity(0.5)
                        Circle().fill(Color.white.opacity(0.06))
                        Circle().strokeBorder(gradient, lineWidth: 2)
                        Image(systemName: "wifi")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.025 * sin(time * 2))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Let's get you connected")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(manager.portalStatus)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                PortalBrowserView(webView: webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("SRMIST · Secure sign in")
                    Spacer()
                    Text("Closes automatically")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 22)
            .background {
                LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.16),
                                        Color(red: 0.04, green: 0.05, blue: 0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(gradient, lineWidth: 3)
                        .blur(radius: 5).opacity(0.4)
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(gradient, lineWidth: 1).opacity(0.65)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct PortalBrowserView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
