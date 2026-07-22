import Foundation
import UserNotifications

/// Presents system notifications from polled messages when Firebase/FCM is unavailable
/// (simulator/dev). This lets the real CLI flow work: publish via curl → app polls → banner
/// with action buttons appears.
enum LocalNotificationPresenter {
    private static let tag = "LocalNotificationPresenter"

    static func presentNewMessages(baseUrl: String, messages: [Message]) {
        guard !messages.isEmpty else { return }
        let user = Store.shared.getBasicUser(baseUrl: baseUrl)
        for message in messages {
            present(baseUrl: baseUrl, message: message, user: user)
        }
    }

    static func present(baseUrl: String, message: Message, user: BasicUser? = nil) {
        let content = UNMutableNotificationContent()
        content.modify(message: message, baseUrl: baseUrl)
        content.attachImageIfNeeded(message: message, user: user) {
            let request = UNNotificationRequest(
                identifier: message.id,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    Log.e(tag, "Failed to present local notification id=\(message.id)", error)
                } else {
                    Log.d(tag, "Presented local notification id=\(message.id) topic=\(message.topic) actions=\(message.actions?.count ?? 0)")
                }
            }
        }
    }
}
