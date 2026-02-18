//
//  AppNotificationDelegate.swift
//  POScannerApp
//

import UIKit
import UserNotifications

final class AppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Keep foreground behavior quiet; users are already in the app flow.
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let deepLinkString = response.notification.request.content.userInfo["deepLink"] as? String,
              let deepLinkURL = URL(string: deepLinkString) else {
            return
        }

        await MainActor.run {
            NotificationCenter.default.post(name: .appDeepLinkRequested, object: deepLinkURL)
        }
    }
}
