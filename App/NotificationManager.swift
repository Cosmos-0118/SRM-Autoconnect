import Foundation
import UserNotifications
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.shared.log("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    func showConnectedToast() {
        let content = UNMutableNotificationContent()
        content.title = "Connected to SRM Wi-Fi"
        content.body = "You're all set."

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.shared.log("Failed to show toast: \(error.localizedDescription)")
            }
        }

        NSSound(named: "Glass")?.play()
    }

    // Show the banner even while the app is frontmost (it never is, but be explicit).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
