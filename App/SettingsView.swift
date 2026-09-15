import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var saveNotice: String?
    @State private var saveFailed = false
    @State private var keychainWarning: String?
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

            if let notice = saveNotice {
                Text(notice)
                    .foregroundColor(saveFailed ? .red : Theme.green)
                    .font(Theme.mono(11))
            }

            if let warning = keychainWarning {
                Text(warning)
                    .foregroundColor(.red)
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
        do {
            guard let user = username.data(using: .utf8),
                  let pass = password.data(using: .utf8),
                  !username.isEmpty, !password.isEmpty else {
                throw SaveError.emptyFields
            }
            try KeychainHelper.shared.save(user, service: "SRMAutoconnect", account: "username")
            try KeychainHelper.shared.save(pass, service: "SRMAutoconnect", account: "password")

            // Verify-after-write: a save that can't be read back is not a save.
            // This is what caught the old silent-failure bug on fresh machines.
            let checkUser = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "username")
            let checkPass = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "password")
            guard checkUser == user, checkPass == pass else {
                throw SaveError.verifyMismatch
            }

            showSaveResult("CREDENTIALS SAVED SECURELY.", failed: false)
            Logger.shared.log("Credentials saved securely.")
        } catch let failure as KeychainHelper.KeychainFailure {
            let message = "SAVE FAILED: \(failure.errorDescription ?? "keychain error") \(KeychainHelper.hint(for: failure.status))"
            showSaveResult(message, failed: true)
            Logger.shared.log(message)
        } catch {
            let message = "SAVE FAILED: \(error.localizedDescription)"
            showSaveResult(message, failed: true)
            Logger.shared.log(message)
        }
    }

    private func showSaveResult(_ message: String, failed: Bool) {
        saveNotice = message
        saveFailed = failed
        // Errors stay up longer so they can actually be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 8 : 2)) {
            saveNotice = nil
        }
    }

    private enum SaveError: LocalizedError {
        case emptyFields
        case verifyMismatch
        var errorDescription: String? {
            switch self {
            case .emptyFields: return "Enter both SRM ID and password first."
            case .verifyMismatch: return "Write succeeded but read-back differed — the login keychain may be locked."
            }
        }
    }

    private func loadCredentials() {
        do {
            if let user = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "username"),
               let usernameStr = String(data: user, encoding: .utf8) {
                self.username = usernameStr
            }
            keychainWarning = nil
        } catch let failure as KeychainHelper.KeychainFailure {
            // Stored credentials exist but are unreadable (denied ACL, locked
            // keychain) — say so instead of showing a blank field.
            keychainWarning = "KEYCHAIN: \(failure.errorDescription ?? "read error") \(KeychainHelper.hint(for: failure.status))"
        } catch {
            keychainWarning = "KEYCHAIN: \(error.localizedDescription)"
        }
        
        if #available(macOS 13.0, *) {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
