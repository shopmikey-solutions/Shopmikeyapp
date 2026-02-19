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
    @State private var selectedTab: Tab = .scan
    @State private var loadedTabs: Set<Tab> = [.scan]
    @State private var pendingDeepLinkTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                if loadedTabs.contains(.scan) {
                    ScanView(environment: environment)
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
                    HistoryView(environment: environment)
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
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDeepLinkRequested)) { notification in
            guard let url = notification.object as? URL else { return }
            handleDeepLink(url)
        }
        .onDisappear {
            pendingDeepLinkTask?.cancel()
            pendingDeepLinkTask = nil
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
}

#if DEBUG
#Preview("Root Tabs") {
    RootTabView()
        .environment(\.appEnvironment, PreviewFixtures.makeEnvironment(seedHistory: true))
}
#endif
