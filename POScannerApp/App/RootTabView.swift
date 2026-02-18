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

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScanView(environment: environment)
            }
            .tag(Tab.scan)
            .tabItem {
                Label("Scan", systemImage: "doc.text.viewfinder")
            }

            NavigationStack {
                HistoryView(environment: environment)
            }
            .tag(Tab.history)
            .tabItem {
                Label("History", systemImage: "clock")
            }

            NavigationStack {
                SettingsView(environment: environment)
            }
            .tag(Tab.settings)
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(AppSurfaceStyle.accent)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .appSensoryFeedback()
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
