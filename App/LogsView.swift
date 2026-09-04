import SwiftUI

struct LogsView: View {
    @ObservedObject var logger = Logger.shared
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("ACTIVITY LOGS")
                    .font(Theme.mono(18, weight: .bold))
                    .foregroundColor(Theme.green)
                Spacer()
                Button(action: {
                    let logString = logger.logs.map(\.text).joined(separator: "\n")
                    let pasteboard = NSPasteboard.general
                    pasteboard.declareTypes([.string], owner: nil)
                    pasteboard.setString(logString, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(Theme.green)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if logger.logs.isEmpty {
                        Text("NO LOGS YET.")
                            .foregroundColor(Theme.dimGreen)
                            .font(Theme.mono(12))
                            .padding()
                    } else {
                        // Keyed by LogEntry.id: identical log lines used to collide
                        // under `id: \.self` and make SwiftUI drop rows.
                        ForEach(logger.logs) { log in
                            Text(log.text)
                                .font(Theme.mono(11))
                                .foregroundColor(Theme.green.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Divider().background(Theme.green.opacity(0.2))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .terminalPanel()
        }
        .padding([.horizontal, .bottom])
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
