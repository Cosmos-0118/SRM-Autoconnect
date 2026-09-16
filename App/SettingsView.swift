import SwiftUI
import ServiceManagement

struct SettingsView: View {
    /// The Settings tab is destroyed and rebuilt every time the user switches
    /// tabs, so anything held in @State here is silently discarded — including a
    /// half-typed password. These drafts outlive the view.
    @ObservedObject private var draft = SettingsDraft.shared
    @State private var saveNotice: String?
    @State private var saveFailed = false
    @State private var keychainWarning: String?
    @State private var openAtLogin = false
    /// Drives the password field's placeholder and the "blank means unchanged"
    /// rule in saveCredentials().
    @State private var hasStoredPassword = false
    @State private var noticeClearWorkItem: DispatchWorkItem?
    @State private var loginItemNeedsApproval = false

    /// Treat "registered, pending the user's approval" as on. Comparing only
    /// against `.enabled` made the toggle snap back to off the moment macOS
    /// asked for approval, which is the normal path on a fresh install.
    private static func loginItemIsOn() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
    
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
                TextField("Enter ID", text: $draft.username)
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
                SecureField(hasStoredPassword ? "Saved — leave blank to keep" : "Enter Password", text: $draft.password)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(10)
                    .terminalPanel()
                    .foregroundColor(Theme.green)
                    .accentColor(Theme.green)
            }

            // No #available check: the deployment target is macOS 13, so the
            // old `if #available(macOS 13.0, *)` was always true and merely hid
            // the fact that this control is unconditional.
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.green))
                    .font(Theme.mono(13))
                    .foregroundColor(Theme.green)
                    .onChange(of: openAtLogin) { newValue in
                        // loadCredentials() syncs this toggle to the actual system status on
                        // every appear, which itself fires onChange — skip if nothing's
                        // actually changing so that sync doesn't look like a user action.
                        let currentlyEnabled = Self.loginItemIsOn()
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
                            // The switch used to stay where the user flicked it
                            // even when the system refused, so it claimed the app
                            // would launch at login when it would not — and the
                            // only trace was a line in a log file nobody reads.
                            // Snap it back and say what happened.
                            Logger.shared.log("Failed to toggle login item: \(error.localizedDescription)")
                            openAtLogin = currentlyEnabled
                            showSaveResult("OPEN AT LOGIN FAILED: \(error.localizedDescription)", failed: true)
                        }
                        loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
                    }

                // .requiresApproval means macOS accepted the registration but is
                // waiting for the user to allow it in System Settings. Nothing
                // said so, and the status check treated it as "off", so the
                // switch silently flipped itself back and the feature looked
                // broken.
                if loginItemNeedsApproval {
                    Text("NEEDS APPROVAL IN SYSTEM SETTINGS › GENERAL › LOGIN ITEMS")
                        .font(Theme.mono(9))
                        .foregroundColor(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
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

            // There was no way to remove saved credentials from inside the app:
            // the Keychain helper had a delete() that nothing ever called, so a
            // user who typed the wrong account, or who wanted their password off
            // a shared Mac, had to go and hunt through Keychain Access for it.
            if hasStoredPassword || !draft.username.isEmpty {
                Button(action: forgetCredentials) {
                    Text("> FORGET SAVED CREDENTIALS <")
                        .font(Theme.mono(11))
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .terminalPanel(tint: Theme.amber)
                        .foregroundColor(Theme.amber)
                }
                .buttonStyle(PlainButtonStyle())
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
            // A trailing space pasted in from elsewhere produces a login that
            // fails forever in a way indistinguishable from a wrong password,
            // and the field gives no visual hint that it is there.
            draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let user = draft.username.data(using: .utf8), !draft.username.isEmpty else {
                throw SaveError.emptyID
            }

            // The password is deliberately never read back into the UI, so after
            // a relaunch this field is blank while the ID field is populated.
            // Treating that blank as "no password" made the common case — fixing
            // a typo in your SRM ID — fail with "enter both fields", with no way
            // to proceed short of retyping the password. An empty field now means
            // "leave the stored password alone"; it is only an error when there
            // is no stored password to leave alone.
            let keepExisting = draft.password.isEmpty
            if keepExisting && !hasStoredPassword {
                throw SaveError.emptyPassword
            }

            try KeychainHelper.shared.save(user, service: "SRMAutoconnect", account: "username")
            let pass = draft.password.data(using: .utf8)
            if let pass, !keepExisting {
                try KeychainHelper.shared.save(pass, service: "SRMAutoconnect", account: "password")
            }

            // Verify-after-write: a save that can't be read back is not a save.
            // This is what caught the old silent-failure bug on fresh machines.
            let checkUser = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "username")
            let checkPass = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "password")
            guard checkUser == user else { throw SaveError.verifyMismatch }
            if !keepExisting {
                guard checkPass == pass else { throw SaveError.verifyMismatch }
            } else {
                guard checkPass != nil else { throw SaveError.verifyMismatch }
            }

            // A stale read-error banner from launch is no longer true once a write
            // has round-tripped successfully.
            keychainWarning = nil
            hasStoredPassword = true
            draft.password = ""
            // Let the manager act on the new credentials now rather than
            // after whatever backoff the old, wrong ones had earned.
            AutoConnectManager.shared.credentialsChanged()
            showSaveResult(keepExisting ? "SRM ID SAVED. PASSWORD UNCHANGED." : "CREDENTIALS SAVED SECURELY.", failed: false)
            Logger.shared.log(keepExisting ? "SRM ID saved; stored password left unchanged." : "Credentials saved securely.")
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

    private func forgetCredentials() {
        do {
            try KeychainHelper.shared.delete(service: "SRMAutoconnect", account: "username")
            try KeychainHelper.shared.delete(service: "SRMAutoconnect", account: "password")
            draft.username = ""
            draft.password = ""
            hasStoredPassword = false
            keychainWarning = nil
            AutoConnectManager.shared.credentialsChanged()
            showSaveResult("SAVED CREDENTIALS REMOVED.", failed: false)
            Logger.shared.log("Saved credentials removed from the keychain.")
        } catch let failure as KeychainHelper.KeychainFailure {
            let message = "REMOVE FAILED: \(failure.errorDescription ?? "keychain error") \(KeychainHelper.hint(for: failure.status))"
            showSaveResult(message, failed: true)
            Logger.shared.log(message)
        } catch {
            showSaveResult("REMOVE FAILED: \(error.localizedDescription)", failed: true)
        }
    }

    private func showSaveResult(_ message: String, failed: Bool) {
        saveNotice = message
        saveFailed = failed
        // Cancel the previous countdown first. Two saves in quick succession used
        // to leave the first save's timer running, so it would blank the *second*
        // save's message seconds after it appeared — worst of all when the second
        // one was an error the user needed to read.
        noticeClearWorkItem?.cancel()
        let item = DispatchWorkItem {
            saveNotice = nil
        }
        noticeClearWorkItem = item
        // Errors stay up longer so they can actually be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 8 : 2), execute: item)
    }

    private enum SaveError: LocalizedError {
        case emptyID
        case emptyPassword
        case verifyMismatch
        var errorDescription: String? {
            switch self {
            case .emptyID: return "Enter your SRM ID first."
            case .emptyPassword: return "Enter your password first."
            case .verifyMismatch: return "Write succeeded but read-back differed — the login keychain may be locked."
            }
        }
    }

    private func loadCredentials() {
        do {
            if !draft.seeded,
               let user = try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "username"),
               let usernameStr = String(data: user, encoding: .utf8) {
                draft.username = usernameStr
            }
            draft.seeded = true
            // Presence only — the password itself is deliberately never loaded
            // back into the UI. Knowing it exists is what lets a blank field mean
            // "keep the saved one" instead of "you forgot to type it".
            hasStoredPassword = (try KeychainHelper.shared.read(service: "SRMAutoconnect", account: "password")) != nil
            keychainWarning = nil
        } catch let failure as KeychainHelper.KeychainFailure {
            // Stored credentials exist but are unreadable (denied ACL, locked
            // keychain) — say so instead of showing a blank field.
            keychainWarning = "KEYCHAIN: \(failure.errorDescription ?? "read error") \(KeychainHelper.hint(for: failure.status))"
        } catch {
            keychainWarning = "KEYCHAIN: \(error.localizedDescription)"
        }
        
        openAtLogin = Self.loginItemIsOn()
        loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
}


/// Survives the Settings tab being torn down and rebuilt on every tab switch.
final class SettingsDraft: ObservableObject {
    static let shared = SettingsDraft()
    private init() {}

    @Published var username = ""
    @Published var password = ""
    /// Whether the SRM ID has been seeded from the keychain yet. Without it,
    /// returning to the tab would re-read the stored ID over the top of an edit
    /// the user had not saved.
    var seeded = false
}
