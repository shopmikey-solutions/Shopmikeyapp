//
//  RootTabView.swift
//  POScannerApp
//

import SwiftUI

struct RootTabView: View {
    private enum Tab: Hashable {
        case scan
        case history
        case settings
    }

    @Environment(\.appEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .scan
    @State private var loadedTabs: Set<Tab> = [.scan]
    @State private var pendingDeepLinkTask: Task<Void, Never>?
    @State private var liveActivitySyncTask: Task<Void, Never>?
    @State private var lastLiveActivitySyncAt: Date?
    @State private var lastLiveActivitySignature: String?
    private let minimumLiveActivitySyncInterval: TimeInterval = 0.9

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
            loadedTabs.insert(tab)
            if tab != .scan {
                scheduleGlobalLiveActivitySync(force: true)
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDeepLinkRequested)) { notification in
            guard let url = notification.object as? URL else { return }
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDraftStoreDidChange)) { _ in
            scheduleGlobalLiveActivitySync()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            scheduleGlobalLiveActivitySync(force: true)
        }
        .onAppear {
            scheduleGlobalLiveActivitySync(force: true)
        }
        .onDisappear {
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = nil
            liveActivitySyncTask?.cancel()
            liveActivitySyncTask = nil
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let route = AppDeepLink.parse(url) else { return }

        switch route {
        case let .scan(openComposer, draftID):
            selectedTab = .scan
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                if let draftID {
                    NotificationCenter.default.post(name: .appResumeScanDraft, object: draftID)
                } else if openComposer {
                    NotificationCenter.default.post(name: .appOpenScanComposer, object: nil)
                }
                pendingDeepLinkTask = nil
            }
        case .history:
            selectedTab = .history
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = nil
        case .settings:
            selectedTab = .settings
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = nil
        }
    }

    @MainActor
    private func scheduleGlobalLiveActivitySync(force: Bool = false) {
        // Scan tab already publishes richer in-flight stage events.
        guard selectedTab != .scan else { return }
        let now = Date()
        if !force,
           let lastLiveActivitySyncAt,
           now.timeIntervalSince(lastLiveActivitySyncAt) < minimumLiveActivitySyncInterval {
            return
        }

        liveActivitySyncTask?.cancel()
        liveActivitySyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: force ? 140_000_000 : 280_000_000)
            guard !Task.isCancelled else { return }
            await syncLiveActivityFromDraftStore()
            lastLiveActivitySyncAt = Date()
        }
    }

    @MainActor
    private func syncLiveActivityFromDraftStore() async {
        let now = Date()
        let drafts = await environment.reviewDraftStore.list()

        guard let draft = liveActivityCandidate(from: drafts, now: now),
              let payload = draft.liveActivityPayload else {
            guard lastLiveActivitySignature != nil else { return }
            lastLiveActivitySignature = nil
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
            String(progressBucket)
        ].joined(separator: "|")
        guard signature != lastLiveActivitySignature else { return }
        lastLiveActivitySignature = signature

        PartsIntakeLiveActivityBridge.sync(
            isActive: true,
            statusText: payload.status,
            detailText: payload.detail,
            progress: payload.progress,
            deepLinkURL: AppDeepLink.scanURL(draftID: draft.id)
        )
    }

    private func liveActivityCandidate(
        from drafts: [ReviewDraftSnapshot],
        now: Date
    ) -> ReviewDraftSnapshot? {
        drafts
            .filter { draft in
                guard draft.isLiveIntakeSession else { return false }
                return now.timeIntervalSince(draft.updatedAt) <= draft.liveActivityRecencyWindow
            }
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return liveActivityPriority(for: $0.workflowState) > liveActivityPriority(for: $1.workflowState)
                }
                return $0.updatedAt > $1.updatedAt
            }
            .first
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
