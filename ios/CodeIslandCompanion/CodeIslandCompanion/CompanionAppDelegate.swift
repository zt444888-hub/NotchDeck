import UIKit

extension Notification.Name {
    /// Posted when a CloudKit database-subscription silent push arrives.
    /// RemoteConversationViewModel observes it to refresh immediately
    /// instead of waiting for the 10s poll (which stays as the fallback).
    static let remoteConversationSilentPush = Notification.Name("RemoteConversationSilentPush")
}

/// Bridges CloudKit silent pushes (database-subscription notifications) to
/// the Remote AI view model.
///
/// Prerequisite: the App ID must enable Push Notifications AND the app needs
/// the aps-environment entitlement (via the "Push Notifications" capability).
/// Until then `registerForRemoteNotifications()` fails benignly and the 10s
/// poll remains the only sync trigger — nothing breaks, the push is just an
/// efficiency win on top.
final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Request an APNs token so CloudKit database-subscription pushes can
        // wake the app on record changes. Fails silently without the
        // entitlement; the poll timer covers that case.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: .remoteConversationSilentPush, object: nil)
        completionHandler(.newData)
    }

    // Expected before the Push capability is enabled; nothing to do.
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
