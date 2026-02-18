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
    }

    var title: String
}

@available(iOS 16.1, *)
actor PartsIntakeLiveActivityManager {
    static let shared = PartsIntakeLiveActivityManager()

    private var activity: Activity<PartsIntakeActivityAttributes>?

    func sync(isProcessing: Bool, statusText: String, detailText: String, progress: Double) async {
        guard isEnabled else {
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard isProcessing else {
            await endCurrent(dismissalPolicy: .default)
            return
        }

        let state = PartsIntakeActivityAttributes.ContentState(
            statusText: statusText,
            detailText: detailText,
            progress: min(1, max(0, progress)),
            updatedAt: Date()
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(6 * 60)
        )

        if let activity {
            await activity.update(content)
            return
        }

        do {
            self.activity = try Activity.request(
                attributes: PartsIntakeActivityAttributes(title: "Parts Intake"),
                content: content,
                pushType: nil
            )
        } catch {
            self.activity = nil
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
            updatedAt: Date()
        )
        let content = ActivityContent(
            state: state,
            staleDate: nil
        )
        await activity.end(content, dismissalPolicy: dismissalPolicy)
        self.activity = nil
    }
}
#endif

enum PartsIntakeLiveActivityBridge {
    static func sync(isProcessing: Bool, statusText: String, detailText: String, progress: Double) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        Task {
            await PartsIntakeLiveActivityManager.shared.sync(
                isProcessing: isProcessing,
                statusText: statusText,
                detailText: detailText,
                progress: progress
            )
        }
        #endif
    }
}
