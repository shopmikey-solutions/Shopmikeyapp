//
//  LocalNotificationService.swift
//  POScannerApp
//

import Foundation
import UserNotifications

struct LocalNotificationService {
    static let enabledKey = "scanLocalNotificationsEnabled"

    enum Event {
        case scanReadyForReview(vendor: String?, lineItemCount: Int, draftID: UUID?)
        case scanFailed
        case submissionSucceeded(vendor: String?, totalCents: Int?)
        case submissionFailed(message: String?, draftID: UUID?)
    }

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notify(_ event: Event) async {
        guard isEnabled else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let payload = payload(for: event)
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.threadIdentifier = payload.threadIdentifier
        content.userInfo = ["deepLink": payload.deepLink.absoluteString]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.35, repeats: false)
        let request = UNNotificationRequest(
            identifier: payload.identifier + "." + UUID().uuidString,
            content: content,
            trigger: trigger
        )

        try? await center.add(request)
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    private var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool {
            return stored
        }
        return true
    }

    private func payload(for event: Event) -> NotificationPayload {
        switch event {
        case let .scanReadyForReview(vendor, lineItemCount, draftID):
            let vendorLabel = normalized(vendor) ?? "Supplier invoice"
            return NotificationPayload(
                identifier: "parts-intake.scan-ready",
                title: "Parts intake ready",
                body: "\(vendorLabel): \(lineItemCount) line item\(lineItemCount == 1 ? "" : "s") parsed. Review before posting.",
                deepLink: AppDeepLink.scanURL(draftID: draftID),
                threadIdentifier: "parts-intake"
            )

        case .scanFailed:
            return NotificationPayload(
                identifier: "parts-intake.scan-failed",
                title: "Scan needs attention",
                body: "Invoice scan could not be completed. Try another capture.",
                deepLink: AppDeepLink.scanURL(openComposer: true),
                threadIdentifier: "parts-intake"
            )

        case let .submissionSucceeded(vendor, totalCents):
            let vendorLabel = normalized(vendor) ?? "Purchase order"
            let total = totalCents.map { currencyString(fromCents: $0) } ?? "Updated"
            return NotificationPayload(
                identifier: "parts-intake.submit-success",
                title: "Submitted to Shopmonkey",
                body: "\(vendorLabel) • \(total)",
                deepLink: AppDeepLink.historyURL,
                threadIdentifier: "parts-intake"
            )

        case let .submissionFailed(message, draftID):
            return NotificationPayload(
                identifier: "parts-intake.submit-failed",
                title: "Submission failed",
                body: normalized(message) ?? "Open history to retry the parts intake.",
                deepLink: AppDeepLink.scanURL(draftID: draftID),
                threadIdentifier: "parts-intake"
            )
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func currencyString(fromCents cents: Int) -> String {
        let amount = Decimal(cents) / 100
        return NSDecimalNumber(decimal: amount).doubleValue.formatted(.currency(code: "USD"))
    }
}

private struct NotificationPayload {
    let identifier: String
    let title: String
    let body: String
    let deepLink: URL
    let threadIdentifier: String
}
