//
//  PartsIntakeLiveActivity.swift
//  POScannerApp
//

import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct PartsIntakeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        var detailText: String
        var progress: Double
        var updatedAt: Date
        var deepLinkURL: String?
    }

    var title: String
}

@available(iOS 16.1, *)
actor PartsIntakeLiveActivityManager {
    static let shared = PartsIntakeLiveActivityManager()

    private var activity: Activity<PartsIntakeActivityAttributes>?
    private var lastSignature: Signature?
    private var lastUpdateAt: Date?

    private struct Signature: Equatable {
        let statusText: String
        let detailText: String
        let progressBucket: Int
        let deepLinkURL: String?
    }

    func sync(
        isActive: Bool,
        statusText: String,
        detailText: String,
        progress: Double,
        deepLinkURL: URL?
    ) async {
        guard isEnabled else {
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard isActive else {
            await endCurrent(dismissalPolicy: .default)
            return
        }

        let clampedProgress = min(1, max(0, progress))
        let signature = Signature(
            statusText: statusText,
            detailText: detailText,
            progressBucket: Int((clampedProgress * 100).rounded()),
            deepLinkURL: deepLinkURL?.absoluteString
        )

        // Avoid churn when app re-enters foreground and repeatedly emits equivalent updates.
        if let lastSignature,
           lastSignature == signature,
           let lastUpdateAt,
           Date().timeIntervalSince(lastUpdateAt) < 1.2 {
            return
        }

        let state = PartsIntakeActivityAttributes.ContentState(
            statusText: statusText,
            detailText: detailText,
            progress: clampedProgress,
            updatedAt: Date(),
            deepLinkURL: deepLinkURL?.absoluteString
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(6 * 60)
        )

        if let activity {
            await activity.update(content)
            self.lastSignature = signature
            self.lastUpdateAt = Date()
            return
        }

        do {
            self.activity = try Activity.request(
                attributes: PartsIntakeActivityAttributes(title: "Parts Intake"),
                content: content,
                pushType: nil
            )
            self.lastSignature = signature
            self.lastUpdateAt = Date()
        } catch {
            self.activity = nil
            self.lastSignature = nil
            self.lastUpdateAt = nil
        }
    }

    private var isEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: "scanLiveActivitiesEnabled") as? Bool {
            return value
        }
        return true
    }

    private func endCurrent(dismissalPolicy: ActivityUIDismissalPolicy) async {
        guard let activity else { return }
        let state = PartsIntakeActivityAttributes.ContentState(
            statusText: "Completed",
            detailText: "Parts intake finished.",
            progress: 1,
            updatedAt: Date(),
            deepLinkURL: nil
        )
        let content = ActivityContent(
            state: state,
            staleDate: nil
        )
        await activity.end(content, dismissalPolicy: dismissalPolicy)
        self.activity = nil
        self.lastSignature = nil
        self.lastUpdateAt = nil
    }
}
#endif

enum PartsIntakeLiveActivityBridge {
    static func sync(
        isActive: Bool,
        statusText: String,
        detailText: String,
        progress: Double,
        deepLinkURL: URL? = nil
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        Task {
            await PartsIntakeLiveActivityManager.shared.sync(
                isActive: isActive,
                statusText: statusText,
                detailText: detailText,
                progress: progress,
                deepLinkURL: deepLinkURL
            )
        }
        #endif
    }
}
