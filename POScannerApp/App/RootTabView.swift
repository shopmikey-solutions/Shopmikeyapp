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
        .tint(.blue)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .appSensoryFeedback()
    }
}

#if DEBUG
#Preview("Root Tabs") {
    RootTabView()
        .environment(\.appEnvironment, PreviewFixtures.makeEnvironment(seedHistory: true))
}
#endif
