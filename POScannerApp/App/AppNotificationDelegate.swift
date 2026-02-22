//
//  AppNotificationDelegate.swift
//  POScannerApp
//

import UIKit
import UserNotifications
import os

final class AppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.App")
    private static var lastURLSignature: String?
    private static var lastURLHandledAt: Date?
    private static let urlDedupInterval: TimeInterval = 1.25

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
            let now = Date()
            let signature = deepLinkURL.absoluteString
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let lastURLSignature = Self.lastURLSignature,
               let lastURLHandledAt = Self.lastURLHandledAt,
               lastURLSignature == signature,
               now.timeIntervalSince(lastURLHandledAt) < Self.urlDedupInterval {
                return
            }
            Self.lastURLSignature = signature
            Self.lastURLHandledAt = now
            Self.logger.debug("Posting deep link request from local notification.")
            NotificationCenter.default.post(name: .appDeepLinkRequested, object: deepLinkURL)
        }
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard AppDeepLink.parse(url) != nil else { return false }

        let now = Date()
        let signature = url.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let lastURLSignature = Self.lastURLSignature,
           let lastURLHandledAt = Self.lastURLHandledAt,
           lastURLSignature == signature,
           now.timeIntervalSince(lastURLHandledAt) < Self.urlDedupInterval {
            return true
        }
        Self.lastURLSignature = signature
        Self.lastURLHandledAt = now

        // In active foreground, SwiftUI's onOpenURL path will handle routing.
        // Keep this delegate as a fallback for launch/background transitions.
        if app.applicationState == .active {
            return true
        }
        Self.logger.debug("Posting deep link request from URL open.")
        NotificationCenter.default.post(name: .appDeepLinkRequested, object: url)
        return true
    }
}
