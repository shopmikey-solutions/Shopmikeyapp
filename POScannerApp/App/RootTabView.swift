//
//  RootTabView.swift
//  POScannerApp
//

import SwiftUI

struct RootTabView: View {
    @Environment(\.appEnvironment) private var environment

    var body: some View {
        TabView {
            NavigationStack {
                ScanView(environment: environment)
            }
            .tabItem {
                Label("Scan", systemImage: "doc.text.viewfinder")
            }

            NavigationStack {
                HistoryView(environment: environment)
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }

            NavigationStack {
                SettingsView(environment: environment)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(.blue)
    }
}

#if DEBUG
#Preview("Root Tabs") {
    RootTabView()
        .environment(\.appEnvironment, PreviewFixtures.makeEnvironment(seedHistory: true))
}
#endif
