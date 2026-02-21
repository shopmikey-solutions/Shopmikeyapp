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
@preconcurrency import ActivityKit

@available(iOS 16.1, *)
struct PartsIntakeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        var detailText: String
        var progress: Double
        var updatedAt: Date
        var deepLinkURL: String?
        var stageToken: String?
    }

    var title: String
}

@available(iOS 16.1, *)
@MainActor
final class PartsIntakeLiveActivityManager {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.LiveActivity")

    static let shared = PartsIntakeLiveActivityManager()

    private var activity: Activity<PartsIntakeActivityAttributes>?
    private var lastSignature: Signature?
    private var lastUpdateAt: Date?
    private var lastDeepLinkRawValue: String?
    private var scheduledEndTask: Task<Void, Never>?
    private var scheduledEndAt: Date?
    private let inactiveWorkflowEndDelay: TimeInterval = 45
    private let terminalCompletionEndDelay: TimeInterval = 12
    private let crossDraftInFlightGuardWindow: TimeInterval = 12
    private let preferredDraftDefaultsKey = "liveActivityPreferredDraftID"

    private struct Signature: Equatable {
        let statusText: String
        let detailText: String
        let progressBucket: Int
        let stageToken: String
        let deepLinkSignature: String
    }

    func sync(
        isActive: Bool,
        statusText: String,
        detailText: String,
        progress: Double,
        deepLinkURL: URL?,
        stageToken: String?
    ) async {
        guard isEnabled else {
            cancelScheduledEnd()
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            cancelScheduledEnd()
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        await bindExistingActivityIfNeeded()

        guard isActive else {
            guard activity != nil || !Activity<PartsIntakeActivityAttributes>.activities.isEmpty else { return }
            scheduleDeferredEnd()
            return
        }

        cancelScheduledEnd()

        guard isMeaningfulActiveState(
            statusText: statusText,
            detailText: detailText,
            progress: progress
        ) else {
            Self.logger.debug("Live Activity sync skipped: state below visibility threshold.")
            await endCurrent(dismissalPolicy: .immediate)
            return
        }

        let normalizedStatusText = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetailText = detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStageToken = normalizedLiveActivityStageToken(stageToken)
        let previousDeepLinkRawValue = self.lastDeepLinkRawValue
        let deepLinkRawValue = deepLinkURL?.absoluteString
        let normalizedDeepLinkRawValue: String? = {
            guard let deepLinkRawValue else { return nil }
            let trimmed = deepLinkRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let deepLinkDidChange = normalizedDeepLinkRawValue != previousDeepLinkRawValue
        let previousDraftID = extractDraftID(from: previousDeepLinkRawValue)
        let nextDraftID = extractDraftID(from: normalizedDeepLinkRawValue)
        let preferredDraftCandidateID = preferredDraftID()
        let now = Date()
        if let lastSignature,
           let lastUpdateAt = self.lastUpdateAt,
           deepLinkDidChange,
           isInFlightStageToken(lastSignature.stageToken),
           !isInFlightStageToken(normalizedStageToken),
           now.timeIntervalSince(lastUpdateAt) <= crossDraftInFlightGuardWindow,
           !shouldHonorDraftSelectionTransition(
               previousDraftID: previousDraftID,
               nextDraftID: nextDraftID,
               preferredDraftID: preferredDraftCandidateID
           ) {
            Self.logger.debug("Live Activity sync skipped: competing non in-flight draft update.")
            return
        }
        var progressBucket = Int((normalizedProgress(progress) * 100).rounded())

        if let lastSignature,
           !shouldAllowProgressRegression(
                statusText: normalizedStatusText,
                previousStageToken: lastSignature.stageToken,
                stageToken: normalizedStageToken,
                deepLinkDidChange: deepLinkDidChange
            ),
           progressBucket < lastSignature.progressBucket {
            progressBucket = lastSignature.progressBucket
        }

        let clampedProgress = min(1, max(0, Double(progressBucket) / 100))
        let previousSignature = self.lastSignature
        let signature = Signature(
            statusText: normalizedStatusText,
            detailText: normalizedDetailText,
            progressBucket: progressBucket,
            stageToken: normalizedStageToken,
            deepLinkSignature: normalizedDeepLinkRawValue ?? ""
        )

        // Avoid churn when app re-enters foreground and repeatedly emits equivalent updates.
        if let lastSignature,
           lastSignature == signature {
            return
        }

        let state = PartsIntakeActivityAttributes.ContentState(
            statusText: normalizedStatusText,
            detailText: normalizedDetailText,
            progress: clampedProgress,
            updatedAt: Date(),
            deepLinkURL: deepLinkRawValue,
            stageToken: normalizedStageToken
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(6 * 60)
        )

        if let activity {
            Self.logger.debug("Live Activity updated. progress=\(clampedProgress, privacy: .public)")
            if shouldRequestProminentUpdate(previous: previousSignature, next: signature),
               let alertConfiguration = alertConfiguration(for: signature) {
                await activity.update(content, alertConfiguration: alertConfiguration)
            } else {
                await activity.update(content)
            }
            self.lastSignature = signature
            self.lastUpdateAt = Date()
            self.lastDeepLinkRawValue = normalizedDeepLinkRawValue ?? self.lastDeepLinkRawValue
            self.updatePreferredDraftID(from: normalizedDeepLinkRawValue)
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
            self.lastDeepLinkRawValue = normalizedDeepLinkRawValue ?? self.lastDeepLinkRawValue
            self.updatePreferredDraftID(from: normalizedDeepLinkRawValue)
        } catch {
            Self.logger.error("Live Activity creation failed: \(String(describing: error), privacy: .public)")
            self.activity = nil
            self.lastSignature = nil
            self.lastUpdateAt = nil
            self.lastDeepLinkRawValue = nil
            self.clearPreferredDraftID()
        }
    }

    private func bindExistingActivityIfNeeded() async {
        if let activity, isStaleTerminalActivity(activity) {
            await activity.end(nil, dismissalPolicy: .immediate)
            self.activity = nil
            self.lastSignature = nil
            self.lastUpdateAt = nil
            self.lastDeepLinkRawValue = nil
            self.clearPreferredDraftID()
            Self.logger.debug("Live Activity manager dismissed stale local terminal activity.")
        }

        var activities = Activity<PartsIntakeActivityAttributes>.activities
        if !activities.isEmpty {
            var retained: [Activity<PartsIntakeActivityAttributes>] = []
            for candidate in activities {
                if isStaleTerminalActivity(candidate) {
                    await candidate.end(nil, dismissalPolicy: .immediate)
                    Self.logger.debug("Live Activity manager dismissed stale terminal activity.")
                } else {
                    retained.append(candidate)
                }
            }
            activities = retained
        }

        guard !activities.isEmpty else {
            // Keep an in-memory reference if ActivityKit has not surfaced the collection yet.
            // This prevents duplicate create/update churn during rapid lifecycle transitions.
            return
        }

        if let activity, activities.contains(where: { $0.id == activity.id }) {
            return
        }

        let resolved = activities.max(by: { lhs, rhs in
            lhs.content.state.updatedAt < rhs.content.state.updatedAt
        }) ?? activities[0]
        activity = resolved

        if activities.count > 1 {
            Self.logger.debug("Live Activity manager resolved multiple active activities; keeping most recent.")
        }
    }

    private func isStaleTerminalActivity(_ candidate: Activity<PartsIntakeActivityAttributes>) -> Bool {
        let state = candidate.content.state
        guard isTerminalCompletionStatus(state.statusText, progress: state.progress) else {
            return false
        }
        return Date().timeIntervalSince(state.updatedAt) >= 90
    }

    private var isEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: "scanLiveActivitiesEnabled") as? Bool {
            return value
        }
        return true
    }

    private func endCurrent(dismissalPolicy: ActivityUIDismissalPolicy) async {
        cancelScheduledEnd()
        var targets: [Activity<PartsIntakeActivityAttributes>] = []
        if let activity {
            targets.append(activity)
        }
        for existing in Activity<PartsIntakeActivityAttributes>.activities where !targets.contains(where: { $0.id == existing.id }) {
            targets.append(existing)
        }
        guard !targets.isEmpty else {
            self.activity = nil
            self.lastSignature = nil
            self.lastUpdateAt = nil
            self.lastDeepLinkRawValue = nil
            self.clearPreferredDraftID()
            return
        }

        let fallbackStatus = targets.first?.content.state.statusText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackDetail = targets.first?.content.state.detailText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackDeepLink = targets.first?.content.state.deepLinkURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorStatus = {
            let fromSignature = lastSignature?.statusText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fromSignature.isEmpty ? fallbackStatus : fromSignature
        }()
        let priorDetail = {
            let fromSignature = lastSignature?.detailText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fromSignature.isEmpty ? fallbackDetail : fromSignature
        }()
        let finalProgress: Double = {
            guard let bucket = lastSignature?.progressBucket else { return 1 }
            return min(1, max(0, Double(bucket) / 100))
        }()
        let terminalCompletion = isTerminalCompletionStatus(priorStatus, progress: finalProgress)
        let finalStatus = terminalCompletion
            ? (priorStatus.isEmpty ? "Submitted" : priorStatus)
            : "Intake paused"
        let finalDetail = terminalCompletion
            ? (priorDetail.isEmpty ? "Parts intake submitted successfully." : priorDetail)
            : "Open ShopMikey to continue."
        let finalDeepLink: String? = {
            let stored = lastDeepLinkRawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            if let fallbackDeepLink, !fallbackDeepLink.isEmpty { return fallbackDeepLink }
            return nil
        }()
        let finalStageToken = terminalCompletion ? "success" : "paused"
        let state = PartsIntakeActivityAttributes.ContentState(
            statusText: finalStatus,
            detailText: finalDetail,
            progress: finalProgress,
            updatedAt: Date(),
            deepLinkURL: finalDeepLink,
            stageToken: finalStageToken
        )
        let content = ActivityContent(
            state: state,
            staleDate: nil
        )
        for target in targets {
            await target.end(content, dismissalPolicy: dismissalPolicy)
        }
        Self.logger.debug("Live Activity ended.")
        self.activity = nil
        self.lastSignature = nil
        self.lastUpdateAt = nil
        self.lastDeepLinkRawValue = nil
        self.clearPreferredDraftID()
    }

    private func scheduleDeferredEnd() {
        let stateStatus = activity?.content.state.statusText ?? ""
        let stateProgress = activity?.content.state.progress ?? 0
        let priorStatus = lastSignature?.statusText ?? stateStatus
        let priorProgress: Double = {
            if let bucket = lastSignature?.progressBucket {
                return min(1, max(0, Double(bucket) / 100))
            }
            return min(1, max(0, stateProgress))
        }()

        let delay = isTerminalCompletionStatus(priorStatus, progress: priorProgress)
            ? terminalCompletionEndDelay
            : inactiveWorkflowEndDelay
        let nanos = UInt64((delay * 1_000_000_000).rounded())
        let targetEndAt = Date().addingTimeInterval(delay)

        if let scheduledEndAt,
           abs(scheduledEndAt.timeIntervalSince(targetEndAt)) < 0.35 {
            return
        }

        scheduledEndTask?.cancel()
        scheduledEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.endCurrent(dismissalPolicy: .immediate)
        }
        scheduledEndAt = targetEndAt
        Self.logger.debug("Live Activity end scheduled in \(delay, privacy: .public)s.")
    }

    private func cancelScheduledEnd() {
        scheduledEndTask?.cancel()
        scheduledEndTask = nil
        scheduledEndAt = nil
    }

    private func isTerminalCompletionStatus(_ statusText: String, progress: Double) -> Bool {
        guard progress >= 0.99 else { return false }
        let normalized = statusText.lowercased()
        return normalized.contains("submit")
            || normalized.contains("complete")
            || normalized.contains("success")
            || normalized.contains("failed")
    }

    private func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private func updatePreferredDraftID(from deepLinkRawValue: String?) {
        guard let draftID = extractDraftID(from: deepLinkRawValue) else { return }
        UserDefaults.standard.set(draftID.uuidString, forKey: preferredDraftDefaultsKey)
    }

    private func preferredDraftID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: preferredDraftDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func clearPreferredDraftID() {
        UserDefaults.standard.removeObject(forKey: preferredDraftDefaultsKey)
    }

    private func extractDraftID(from deepLinkRawValue: String?) -> UUID? {
        guard let deepLinkRawValue else { return nil }
        guard let url = URL(string: deepLinkRawValue) else { return nil }
        guard let route = AppDeepLink.parse(url) else { return nil }
        switch route {
        case let .scan(_, draftID):
            return draftID
        case .history, .settings:
            return nil
        }
    }

    private func shouldHonorDraftSelectionTransition(
        previousDraftID: UUID?,
        nextDraftID: UUID?,
        preferredDraftID: UUID?
    ) -> Bool {
        guard let nextDraftID else { return false }
        if previousDraftID == nextDraftID {
            return true
        }
        if let preferredDraftID, preferredDraftID == nextDraftID {
            return true
        }
        return false
    }

    private func normalizedLiveActivityStageToken(_ token: String?) -> String {
        guard let token else { return "" }
        return token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func shouldAllowProgressRegression(
        statusText: String,
        previousStageToken: String,
        stageToken: String,
        deepLinkDidChange: Bool
    ) -> Bool {
        if deepLinkDidChange {
            return true
        }
        if liveActivityStageOrder(for: stageToken) < liveActivityStageOrder(for: previousStageToken) {
            return true
        }
        if ["capture", "ocr", "parse"].contains(stageToken) {
            return true
        }
        let normalized = statusText.lowercased()
        return normalized.contains("step 1 of 4")
            || normalized.contains("step 2 of 4")
            || normalized.contains("capture in progress")
            || normalized.contains("capturing invoice")
            || normalized.contains("reviewing ocr")
            || normalized.contains("parsing line items")
    }

    private func liveActivityStageOrder(for token: String) -> Int {
        switch token {
        case "capture":
            return 0
        case "ocr":
            return 1
        case "parse":
            return 2
        case "draft":
            return 3
        case "submit":
            return 4
        case "success":
            return 5
        case "fail":
            return 6
        default:
            return Int.max
        }
    }

    private func isInFlightStageToken(_ token: String) -> Bool {
        switch token {
        case "capture", "ocr", "parse", "submit":
            return true
        case "draft", "success", "fail", "paused", "intake":
            return false
        default:
            return false
        }
    }

    private func shouldRequestProminentUpdate(previous: Signature?, next: Signature) -> Bool {
        guard previous?.stageToken != next.stageToken else { return false }
        switch next.stageToken {
        case "submit", "success", "fail":
            return true
        default:
            return false
        }
    }

    private func alertConfiguration(for signature: Signature) -> AlertConfiguration? {
        switch signature.stageToken {
        case "submit":
            return AlertConfiguration(
                title: "Submitting to Shopmonkey",
                body: "Posting purchase order...",
                sound: .default
            )
        case "success":
            return AlertConfiguration(
                title: "Submitted",
                body: "Purchase order posted successfully.",
                sound: .default
            )
        case "fail":
            return AlertConfiguration(
                title: "Submission needs attention",
                body: "Open ShopMikey to review and retry.",
                sound: .default
            )
        default:
            return nil
        }
    }

    private func isMeaningfulActiveState(
        statusText: String,
        detailText: String,
        progress: Double
    ) -> Bool {
        let hasReadableStatus = !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadableDetail = !detailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let normalized = normalizedProgress(progress)
        return hasReadableStatus && hasReadableDetail && normalized >= 0.20
    }
}
#endif

@MainActor
enum PartsIntakeLiveActivityBridge {
    private struct PendingSyncPayload {
        let isActive: Bool
        let statusText: String
        let detailText: String
        let progress: Double
        let deepLinkURL: URL?
        let stageToken: String?
    }

    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.LiveActivity")
    private static var firstForegroundSyncAt: Date?
    private static var hasLoggedGatePassForForegroundSession: Bool = false
    private static var hasLoggedInactiveBlockForForegroundSession: Bool = false
    private static var hasLoggedStartupGateBlockForForegroundSession: Bool = false
    private static var deferredSyncTask: Task<Void, Never>?
    private static var pendingSyncPayload: PendingSyncPayload?
    private static let startupGateInterval: TimeInterval = 0.25
    private static let minimumDeferredSyncDelay: TimeInterval = 0.08

    @MainActor
    static func sync(
        isActive: Bool,
        statusText: String,
        detailText: String,
        progress: Double,
        deepLinkURL: URL? = nil,
        stageToken: String? = nil
    ) {
        #if canImport(UIKit)
        if isActive, UIApplication.shared.applicationState == .background {
            cancelDeferredSync()
            dispatchToManager(
                isActive: isActive,
                statusText: statusText,
                detailText: detailText,
                progress: progress,
                deepLinkURL: deepLinkURL,
                stageToken: stageToken
            )
            return
        }
        #endif

        if !isActive {
            cancelDeferredSync()
        }

        if isActive && !readyForForegroundSync() {
            if !hasLoggedStartupGateBlockForForegroundSession {
                logger.debug("Live Activity bridge blocked by startup foreground gate.")
                hasLoggedStartupGateBlockForForegroundSession = true
            }
            queueDeferredSync(
                PendingSyncPayload(
                    isActive: isActive,
                    statusText: statusText,
                    detailText: detailText,
                    progress: progress,
                    deepLinkURL: deepLinkURL,
                    stageToken: stageToken
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
            deepLinkURL: deepLinkURL,
            stageToken: stageToken
        )
    }

    @MainActor
    private static func readyForForegroundSync() -> Bool {
        #if canImport(UIKit)
        let state = UIApplication.shared.applicationState
        guard state != .background else {
            if !hasLoggedInactiveBlockForForegroundSession {
                logger.debug("Live Activity gate blocked because app is backgrounded.")
                hasLoggedInactiveBlockForForegroundSession = true
            }
            firstForegroundSyncAt = nil
            hasLoggedGatePassForForegroundSession = false
            hasLoggedStartupGateBlockForForegroundSession = false
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
            if isReady {
                hasLoggedStartupGateBlockForForegroundSession = false
            }
            return isReady
        }

        firstForegroundSyncAt = now
        hasLoggedGatePassForForegroundSession = false
        hasLoggedStartupGateBlockForForegroundSession = false
        logger.debug("Live Activity foreground gate started.")
        return false
        #else
        return true
        #endif
    }

    @MainActor
    private static func queueDeferredSync(_ payload: PendingSyncPayload) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else {
            pendingSyncPayload = nil
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
                deepLinkURL: pending.deepLinkURL,
                stageToken: pending.stageToken
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
        deepLinkURL: URL?,
        stageToken: String?
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        Task {
            await PartsIntakeLiveActivityManager.shared.sync(
                isActive: isActive,
                statusText: statusText,
                detailText: detailText,
                progress: progress,
                deepLinkURL: deepLinkURL,
                stageToken: stageToken
            )
        }
        #endif
    }
}
