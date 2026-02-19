//
//  PartsIntakeLiveActivity.swift
//  POScannerApp
//

import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

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
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.LiveActivity")

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
            Self.logger.debug("Live Activity sync skipped: disabled by user setting.")
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.debug("Live Activity sync skipped: activities disabled on device.")
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard isActive else {
            Self.logger.debug("Live Activity sync ending because workflow is inactive.")
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard isMeaningfulActiveState(
            statusText: statusText,
            detailText: detailText,
            progress: progress
        ) else {
            Self.logger.debug("Live Activity sync skipped: state below visibility threshold.")
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        let clampedProgress = normalizedProgress(progress)
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
            Self.logger.debug("Live Activity sync skipped due to churn guard.")
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
            Self.logger.debug("Live Activity updated. progress=\(clampedProgress, privacy: .public)")
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
            Self.logger.info("Live Activity created. progress=\(clampedProgress, privacy: .public)")
            self.lastSignature = signature
            self.lastUpdateAt = Date()
        } catch {
            Self.logger.error("Live Activity creation failed: \(String(describing: error), privacy: .public)")
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
        let finalStatus = lastSignature?.statusText ?? "Parts intake complete"
        let finalDetail = lastSignature?.detailText ?? "Tap to open ShopMikey."
        let finalProgress: Double = {
            guard let bucket = lastSignature?.progressBucket else { return 1 }
            return min(1, max(0, Double(bucket) / 100))
        }()
        let state = PartsIntakeActivityAttributes.ContentState(
            statusText: finalStatus,
            detailText: finalDetail,
            progress: finalProgress,
            updatedAt: Date(),
            deepLinkURL: lastSignature?.deepLinkURL
        )
        let content = ActivityContent(
            state: state,
            staleDate: nil
        )
        await activity.end(content, dismissalPolicy: dismissalPolicy)
        Self.logger.debug("Live Activity ended.")
        self.activity = nil
        self.lastSignature = nil
        self.lastUpdateAt = nil
    }

    private func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private func isMeaningfulActiveState(
        statusText: String,
        detailText: String,
        progress: Double
    ) -> Bool {
        let hasReadableStatus = !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadableDetail = !detailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let normalized = normalizedProgress(progress)
        return hasReadableStatus && hasReadableDetail && normalized >= 0.55
    }
}
#endif

enum PartsIntakeLiveActivityBridge {
    private struct PendingSyncPayload {
        let isActive: Bool
        let statusText: String
        let detailText: String
        let progress: Double
        let deepLinkURL: URL?
    }

    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.LiveActivity")
    private static var firstForegroundSyncAt: Date?
    private static var hasLoggedGatePassForForegroundSession: Bool = false
    private static var hasLoggedInactiveBlockForForegroundSession: Bool = false
    private static var deferredSyncTask: Task<Void, Never>?
    private static var pendingSyncPayload: PendingSyncPayload?
    private static let startupGateInterval: TimeInterval = 0.6
    private static let minimumDeferredSyncDelay: TimeInterval = 0.15

    @MainActor
    static func sync(
        isActive: Bool,
        statusText: String,
        detailText: String,
        progress: Double,
        deepLinkURL: URL? = nil
    ) {
        if !isActive {
            cancelDeferredSync()
        }

        if isActive && !readyForForegroundSync() {
            logger.debug("Live Activity bridge blocked by startup foreground gate.")
            queueDeferredSync(
                PendingSyncPayload(
                    isActive: isActive,
                    statusText: statusText,
                    detailText: detailText,
                    progress: progress,
                    deepLinkURL: deepLinkURL
                )
            )
            return
        }

        cancelDeferredSync()
        dispatchToManager(
            isActive: isActive,
            statusText: statusText,
            detailText: detailText,
            progress: progress,
            deepLinkURL: deepLinkURL
        )
    }

    @MainActor
    private static func readyForForegroundSync() -> Bool {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else {
            if !hasLoggedInactiveBlockForForegroundSession {
                logger.debug("Live Activity gate blocked because app is not active.")
                hasLoggedInactiveBlockForForegroundSession = true
            }
            firstForegroundSyncAt = nil
            hasLoggedGatePassForForegroundSession = false
            return false
        }
        hasLoggedInactiveBlockForForegroundSession = false

        let now = Date()
        if let firstForegroundSyncAt {
            let isReady = now.timeIntervalSince(firstForegroundSyncAt) >= startupGateInterval
            if isReady, !hasLoggedGatePassForForegroundSession {
                logger.debug("Live Activity gate passed after startup delay.")
                hasLoggedGatePassForForegroundSession = true
            }
            return isReady
        }

        firstForegroundSyncAt = now
        hasLoggedGatePassForForegroundSession = false
        logger.debug("Live Activity foreground gate started.")
        return false
        #else
        return true
        #endif
    }

    @MainActor
    private static func queueDeferredSync(_ payload: PendingSyncPayload) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else {
            pendingSyncPayload = payload
            deferredSyncTask?.cancel()
            deferredSyncTask = nil
            return
        }
        #endif

        pendingSyncPayload = payload
        deferredSyncTask?.cancel()

        let remainingDelay = max(minimumDeferredSyncDelay, remainingGateDelay())
        deferredSyncTask = Task { @MainActor in
            let nanos = UInt64((remainingDelay * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled,
                  let pending = pendingSyncPayload else { return }
            pendingSyncPayload = nil
            sync(
                isActive: pending.isActive,
                statusText: pending.statusText,
                detailText: pending.detailText,
                progress: pending.progress,
                deepLinkURL: pending.deepLinkURL
            )
        }
    }

    @MainActor
    private static func cancelDeferredSync() {
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        pendingSyncPayload = nil
    }

    @MainActor
    private static func remainingGateDelay() -> TimeInterval {
        guard let firstForegroundSyncAt else { return startupGateInterval }
        return max(0, startupGateInterval - Date().timeIntervalSince(firstForegroundSyncAt))
    }

    private static func dispatchToManager(
        isActive: Bool,
        statusText: String,
        detailText: String,
        progress: Double,
        deepLinkURL: URL?
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
