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
    }

    private func handleDeepLink(_ url: URL) {
        guard let route = AppDeepLink.parse(url) else { return }

        switch route {
        case let .scan(openComposer, draftID):
            selectedTab = .scan
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                if let draftID {
                    NotificationCenter.default.post(name: .appResumeScanDraft, object: draftID)
                } else if openComposer {
                    NotificationCenter.default.post(name: .appOpenScanComposer, object: nil)
                }
            }
        case .history:
            selectedTab = .history
        case .settings:
            selectedTab = .settings
        }
    }
}

#if DEBUG
#Preview("Root Tabs") {
    RootTabView()
        .environment(\.appEnvironment, PreviewFixtures.makeEnvironment(seedHistory: true))
}
#endif
