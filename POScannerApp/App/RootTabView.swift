//
//  RootTabView.swift
//  POScannerApp
//

import SwiftUI
import os

struct RootTabView: View {
    private enum Tab: Hashable {
        case scan
        case history
        case settings
    }

    private static let deepLinkLogger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.DeepLink")
    nonisolated(unsafe) private static var lastGlobalRawDeepLinkSignature: String?
    nonisolated(unsafe) private static var lastGlobalRawDeepLinkHandledAt: Date?
    nonisolated(unsafe) private static var lastGlobalNormalizedDeepLinkSignature: String?
    nonisolated(unsafe) private static var lastGlobalNormalizedDeepLinkHandledAt: Date?

    @Environment(\.appEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .scan
    @State private var loadedTabs: Set<Tab> = [.scan]
    @State private var pendingDeepLinkTask: Task<Void, Never>?
    @State private var liveActivitySyncTask: Task<Void, Never>?
    @State private var lastLiveActivitySyncAt: Date?
    @State private var lastLiveActivitySignature: String?
    private let minimumLiveActivitySyncInterval: TimeInterval = 0.9
    private let deepLinkDedupInterval: TimeInterval = 8.0
    private let rawDeepLinkDedupInterval: TimeInterval = 8.0
    private let preferredDraftDefaultsKey = "liveActivityPreferredDraftID"
    private let pendingResumeDraftDefaultsKey = "pendingResumeDraftID"
    private let pendingOpenComposerDefaultsKey = "pendingOpenScanComposer"

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                if loadedTabs.contains(.scan) {
                    ScanView(
                        environment: environment,
                        isTabActive: selectedTab == .scan
                    )
                } else {
                    Color.clear
                }
            }
            .tag(Tab.scan)
            .tabItem {
                Label("Scan", systemImage: "doc.text.viewfinder")
            }
            .accessibilityLabel("Scan")
            .accessibilityHint("Capture invoices and review current intake sessions.")
            .accessibilityIdentifier("tab.scan")

            NavigationStack {
                if loadedTabs.contains(.history) {
                    HistoryView(
                        environment: environment,
                        isTabActive: selectedTab == .history
                    )
                } else {
                    Color.clear
                }
            }
            .tag(Tab.history)
            .tabItem {
                Label("History", systemImage: "clock")
            }
            .accessibilityLabel("History")
            .accessibilityHint("Browse submitted purchase orders and in-progress drafts.")
            .accessibilityIdentifier("tab.history")

            NavigationStack {
                if loadedTabs.contains(.settings) {
                    SettingsView(environment: environment)
                } else {
                    Color.clear
                }
            }
            .tag(Tab.settings)
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityLabel("Settings")
            .accessibilityHint("Configure Shopmonkey connection and app behavior.")
            .accessibilityIdentifier("tab.settings")
        }
        .tint(AppSurfaceStyle.accent)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .appSensoryFeedback()
        .onChange(of: selectedTab) { _, tab in
            self.loadedTabs.insert(tab)
            if tab != .scan {
                self.scheduleGlobalLiveActivitySync(force: true)
            }
        }
        .onOpenURL { url in
            Task { @MainActor in
                await Task.yield()
                self.handleDeepLink(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDeepLinkRequested)) { notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor in
                await Task.yield()
                self.handleDeepLink(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDraftStoreDidChange)) { _ in
            self.scheduleGlobalLiveActivitySync()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            self.scheduleGlobalLiveActivitySync(force: true)
        }
        .onAppear {
            self.scheduleGlobalLiveActivitySync(force: true)
        }
        .onDisappear {
            self.pendingDeepLinkTask?.cancel()
            self.pendingDeepLinkTask = nil
            self.liveActivitySyncTask?.cancel()
            self.liveActivitySyncTask = nil
        }
    }

    private func handleDeepLink(_ url: URL) {
        let now = self.environment.dateProvider.now
        let rawSignature = url.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let lastRawDeepLinkSignature = Self.lastGlobalRawDeepLinkSignature,
           let lastRawDeepLinkHandledAt = Self.lastGlobalRawDeepLinkHandledAt,
           rawSignature == lastRawDeepLinkSignature,
           now.timeIntervalSince(lastRawDeepLinkHandledAt) < self.rawDeepLinkDedupInterval {
            return
        }
        Self.lastGlobalRawDeepLinkSignature = rawSignature
        Self.lastGlobalRawDeepLinkHandledAt = now

        guard let parsedRoute = AppDeepLink.parse(url) else { return }
        let route = self.normalizedDeepLinkRoute(from: parsedRoute)
        if case let .scan(_, draftID) = route,
           let draftID {
            UserDefaults.standard.set(draftID.uuidString, forKey: self.preferredDraftDefaultsKey)
        }
        let signature = self.deepLinkSignature(for: route)
        if self.pendingDeepLinkTask != nil,
           Self.lastGlobalNormalizedDeepLinkSignature == signature {
            return
        }
        if let lastDeepLinkSignature = Self.lastGlobalNormalizedDeepLinkSignature,
           let lastDeepLinkHandledAt = Self.lastGlobalNormalizedDeepLinkHandledAt,
           lastDeepLinkSignature == signature,
           now.timeIntervalSince(lastDeepLinkHandledAt) < deepLinkDedupInterval {
            return
        }
        Self.lastGlobalNormalizedDeepLinkSignature = signature
        Self.lastGlobalNormalizedDeepLinkHandledAt = now
        Self.deepLinkLogger.debug("Handling deep link: \(url.absoluteString, privacy: .public)")

        switch route {
        case let .scan(openComposer, draftID):
            selectedTab = .scan
            if let draftID {
                UserDefaults.standard.set(draftID.uuidString, forKey: self.pendingResumeDraftDefaultsKey)
                UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            } else if openComposer {
                UserDefaults.standard.set(true, forKey: self.pendingOpenComposerDefaultsKey)
                UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
            }
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                if let draftID {
                    NotificationCenter.default.post(name: .appResumeScanDraft, object: draftID)
                } else if openComposer {
                    NotificationCenter.default.post(name: .appOpenScanComposer, object: nil)
                }
                self.pendingDeepLinkTask = nil
            }
        case .history:
            selectedTab = .history
            UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = nil
        case .settings:
            selectedTab = .settings
            UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = nil
        }
    }

    private func normalizedDeepLinkRoute(from route: AppDeepLink.Route) -> AppDeepLink.Route {
        switch route {
        case let .scan(_, draftID):
            if let draftID {
                return .scan(openComposer: false, draftID: draftID)
            }
            return .scan(openComposer: true, draftID: nil)
        case .history, .settings:
            return route
        }
    }

    private func deepLinkSignature(for route: AppDeepLink.Route) -> String {
        switch route {
        case let .scan(openComposer, draftID):
            return "scan|\(openComposer ? "1" : "0")|\(draftID?.uuidString ?? "")"
        case .history:
            return "history"
        case .settings:
            return "settings"
        }
    }

    @MainActor
    private func scheduleGlobalLiveActivitySync(force: Bool = false) {
        // Scan tab already publishes richer in-flight stage events.
        guard selectedTab != .scan else { return }
        let now = environment.dateProvider.now
        if !force,
           let lastLiveActivitySyncAt,
           now.timeIntervalSince(lastLiveActivitySyncAt) < minimumLiveActivitySyncInterval {
            return
        }

        liveActivitySyncTask?.cancel()
        liveActivitySyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: force ? 140_000_000 : 280_000_000)
            guard !Task.isCancelled else { return }
            await self.syncLiveActivityFromDraftStore()
            self.lastLiveActivitySyncAt = self.environment.dateProvider.now
        }
    }

    @MainActor
    private func syncLiveActivityFromDraftStore() async {
        let now = environment.dateProvider.now
        let drafts = await environment.reviewDraftStore.list()

        guard let draft = liveActivityCandidate(from: drafts, now: now),
              let payload = draft.liveActivityPayload else {
            guard lastLiveActivitySignature != nil else { return }
            lastLiveActivitySignature = nil
            UserDefaults.standard.removeObject(forKey: self.preferredDraftDefaultsKey)
            PartsIntakeLiveActivityBridge.sync(
                isActive: false,
                statusText: "",
                detailText: "",
                progress: 0,
                deepLinkURL: nil
            )
            return
        }

        let progressBucket = Int((min(1, max(0, payload.progress)) * 100).rounded())
        let signature = [
            draft.id.uuidString,
            payload.status.trimmingCharacters(in: .whitespacesAndNewlines),
            payload.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            String(progressBucket),
            draft.liveActivityStageToken
        ].joined(separator: "|")
        guard signature != lastLiveActivitySignature else { return }
        lastLiveActivitySignature = signature

        PartsIntakeLiveActivityBridge.sync(
            isActive: true,
            statusText: payload.status,
            detailText: payload.detail,
            progress: payload.progress,
            deepLinkURL: AppDeepLink.scanURL(draftID: draft.id),
            stageToken: draft.liveActivityStageToken
        )
    }

    private func liveActivityCandidate(
        from drafts: [ReviewDraftSnapshot],
        now: Date
    ) -> ReviewDraftSnapshot? {
        let eligibleDrafts = drafts
            .filter { draft in
                self.isDraftEligibleForGlobalLiveActivity(draft, now: now)
            }
        guard !eligibleDrafts.isEmpty else { return nil }

        let sortedDrafts = eligibleDrafts
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return self.liveActivityPriority(for: $0.workflowState) > self.liveActivityPriority(for: $1.workflowState)
                }
                return $0.updatedAt > $1.updatedAt
            }

        if let preferredDraftID = self.preferredLiveActivityDraftID(),
           let preferredDraft = eligibleDrafts.first(where: { $0.id == preferredDraftID }),
           self.shouldPreferDraftForGlobalLiveActivity(
            preferredDraft,
            over: sortedDrafts.first
           ) {
            return preferredDraft
        }

        return sortedDrafts.first
    }

    private func shouldPreferDraftForGlobalLiveActivity(
        _ preferredDraft: ReviewDraftSnapshot,
        over newestDraft: ReviewDraftSnapshot?
    ) -> Bool {
        guard let newestDraft else { return true }
        if preferredDraft.id == newestDraft.id { return true }
        return preferredDraft.updatedAt >= newestDraft.updatedAt
    }

    private func isDraftEligibleForGlobalLiveActivity(_ draft: ReviewDraftSnapshot, now: Date) -> Bool {
        switch draft.workflowState {
        case .reviewReady, .reviewEdited, .submitting:
            return now.timeIntervalSince(draft.updatedAt) <= draft.liveActivityRecencyWindow
        case .scanning, .ocrReview, .parsing:
            // Global sync runs outside the scan tab; keep only resumable review/submission states here.
            return false
        case .failed:
            return false
        }
    }

    private func preferredLiveActivityDraftID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: self.preferredDraftDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func liveActivityPriority(for state: ReviewDraftSnapshot.WorkflowState) -> Int {
        switch state {
        case .submitting:
            return 5
        case .reviewEdited:
            return 4
        case .reviewReady:
            return 3
        case .parsing:
            return 2
        case .ocrReview:
            return 1
        case .scanning:
            return 0
        case .failed:
            return -1
        }
    }

}

#if DEBUG
#Preview("Root Tabs") {
    RootTabView()
        .environment(\.appEnvironment, PreviewFixtures.makeEnvironment(seedHistory: true))
}
#endif
