//
//  AppNotificationDelegate.swift
//  POScannerApp
//

import UIKit
import UserNotifications
import os

final class AppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.App")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.logger.info("Application didFinishLaunching.")
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
            Self.logger.debug("Posting deep link request from local notification.")
            NotificationCenter.default.post(name: .appDeepLinkRequested, object: deepLinkURL)
        }
    }
}
