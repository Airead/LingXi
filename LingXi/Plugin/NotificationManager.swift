import Foundation
import UserNotifications

/// Manages system notifications for plugins.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var hasRequestedAuthorization = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Check current notification authorization status.
    func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    /// Request notification authorization if not already requested.
    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                DebugLog.log("[NotificationManager] Authorization request error: \(error)")
            } else if !granted {
                DebugLog.log("[NotificationManager] Notification authorization denied by user")
            } else {
                DebugLog.log("[NotificationManager] Notification authorization granted")
            }
        }
    }

    /// Post a local notification with the given title and message.
    /// - Parameters:
    ///   - title: The notification title.
    ///   - message: The notification body.
    /// - Returns: `true` if the notification was scheduled successfully.
    @discardableResult
    func notify(title: String, message: String) -> Bool {
        requestAuthorizationIfNeeded()

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Immediate notification
        )

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        center.add(request) { error in
            if let error {
                DebugLog.log("[NotificationManager] Failed to schedule notification: \(error)")
            }
            success = (error == nil)
            semaphore.signal()
        }
        semaphore.wait()

        return success
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Allow notifications to display as banners even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
