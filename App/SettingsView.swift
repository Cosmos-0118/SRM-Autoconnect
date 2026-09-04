import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var isSaved = false
    @State private var openAtLogin = false
    
    var body: some View {
        ScrollView {
        VStack(spacing: 14) {
            Text("SETTINGS")
                .font(Theme.mono(18, weight: .bold))
                .foregroundColor(Theme.green)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("SRM ID")
                    .foregroundColor(Theme.dimGreen)
                    .font(Theme.mono(13))
                TextField("Enter ID", text: $username)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(10)
                    .terminalPanel()
                    .foregroundColor(Theme.green)
                    .accentColor(Theme.green)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("PASSWORD")
                    .foregroundColor(Theme.dimGreen)
                    .font(Theme.mono(13))
                SecureField("Enter Password", text: $password)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(10)
                    .terminalPanel()
                    .foregroundColor(Theme.green)
                    .accentColor(Theme.green)
            }

            if #available(macOS 13.0, *) {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.green))
                    .font(Theme.mono(13))
                    .foregroundColor(Theme.green)
                    .onChange(of: openAtLogin) { newValue in
                        // loadCredentials() syncs this toggle to the actual system status on
                        // every appear, which itself fires onChange — skip if nothing's
                        // actually changing so that sync doesn't look like a user action.
                        let currentlyEnabled = SMAppService.mainApp.status == .enabled
                        guard newValue != currentlyEnabled else { return }
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                                Logger.shared.log("Enabled Open at Login")
                            } else {
                                try SMAppService.mainApp.unregister()
                                Logger.shared.log("Disabled Open at Login")
                            }
                        } catch {
                            Logger.shared.log("Failed to toggle login item: \(error.localizedDescription)")
                        }
                    }
            }
            
            Button(action: saveCredentials) {
                Text("> SAVE <")
                    .font(Theme.mono(13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .terminalPanel()
                    .foregroundColor(Theme.green)
            }
            .buttonStyle(PlainButtonStyle())

            if isSaved {
                Text("CREDENTIALS SAVED SECURELY.")
                    .foregroundColor(Theme.green)
                    .font(Theme.mono(11))
            }

            Spacer(minLength: 24)

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("> QUIT <")
                    .font(Theme.mono(12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .terminalPanel(tint: .red)
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding([.horizontal, .bottom])
        .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear(perform: loadCredentials)
    }
    
    private func saveCredentials() {
        if let user = username.data(using: .utf8) {
            KeychainHelper.shared.save(user, service: "SRMAutoconnect", account: "username")
        }
        if let pass = password.data(using: .utf8) {
            KeychainHelper.shared.save(pass, service: "SRMAutoconnect", account: "password")
        }
        isSaved = true
        Logger.shared.log("Credentials saved securely.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isSaved = false
        }
    }
    
    private func loadCredentials() {
        if let user = KeychainHelper.shared.read(service: "SRMAutoconnect", account: "username"),
           let usernameStr = String(data: user, encoding: .utf8) {
            self.username = usernameStr
        }
        
        if #available(macOS 13.0, *) {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
