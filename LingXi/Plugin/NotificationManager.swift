import Foundation
import UserNotifications

/// Manages system notifications for plugins.
final class NotificationManager {
    static let shared = NotificationManager()

    private var hasRequestedAuthorization = false

    private init() {}

    /// Request notification authorization if not already requested.
    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Ignore result; notifications will simply not show if denied.
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
            success = (error == nil)
            semaphore.signal()
        }
        semaphore.wait()

        return success
    }
}
