import SwiftUI

struct LogsView: View {
    @ObservedObject var logger = Logger.shared
    @State private var actionNote: String?
    @State private var noteClearWorkItem: DispatchWorkItem?

    private func copyLogs() {
        let logString = logger.logs.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(logString, forType: .string)
        flash("COPIED \(logger.logs.count)")
    }

    private func clearLogs() {
        logger.clearUILogs()
        flash("CLEARED")
    }

    private func flash(_ message: String) {
        actionNote = message
        noteClearWorkItem?.cancel()
        let item = DispatchWorkItem { actionNote = nil }
        noteClearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("ACTIVITY LOGS")
                    .font(Theme.mono(18, weight: .bold))
                    .foregroundColor(Theme.green)
                Spacer()
                // Copying used to give no acknowledgement whatsoever: the icon
                // did not change, nothing appeared, and the clipboard is
                // invisible — so the only way to find out whether the click had
                // registered was to go and paste somewhere else.
                if let note = actionNote {
                    Text(note)
                        .font(Theme.mono(10))
                        .foregroundColor(Theme.green)
                        .transition(.opacity)
                }
                Button(action: copyLogs) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(Theme.green)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy all logs to the clipboard")
                .accessibilityLabel("Copy logs")
                .disabled(logger.logs.isEmpty)

                Button(action: clearLogs) {
                    Image(systemName: "trash")
                        .foregroundColor(Theme.green)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Clear the list below. The log file on disk is kept.")
                .accessibilityLabel("Clear logs")
                .disabled(logger.logs.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: actionNote)

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
