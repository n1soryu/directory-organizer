import AppKit
import Foundation
import UserNotifications

/// macOS notifications. They only work from the bundled .app (`scripts/build-app.sh`):
/// a bare `swift run` binary has no bundle identifier, so notifications are skipped there.
@MainActor
final class Notifier {
    enum Status: Equatable {
        case unknown, notDetermined, allowed, denied
        /// Running unbundled (`swift run`): notifications aren't possible.
        case unavailable

        var description: String {
            switch self {
            case .unknown: "checking…"
            case .notDetermined: "not asked yet"
            case .allowed: "allowed"
            case .denied: "turned off in System Settings → Notifications"
            case .unavailable: "only in the bundled app (scripts/build-app.sh)"
            }
        }
    }

    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func status() async -> Status {
        guard Self.isBundled else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    func requestAuthorization() async -> Status {
        guard Self.isBundled else { return .unavailable }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await status()
    }

    /// `page` is opened in the dashboard when you click the notification.
    /// True if the notification was handed to macOS to show.
    @discardableResult
    func send(title: String, body: String, page: AppModel.Page) async -> Bool {
        guard Self.isBundled, await status() == .allowed else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["page": page.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        return (try? await UNUserNotificationCenter.current().add(request)) != nil
    }
}
