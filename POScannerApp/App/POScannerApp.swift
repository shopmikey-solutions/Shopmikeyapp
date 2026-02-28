//
//  POScannerApp.swift
//  POScannerApp
//
//  Created by Michael Bordeaux on 2/15/26.
//

import SwiftUI

@main
struct POScannerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var appNotificationDelegate
    private let environment: AppEnvironment
    @State private var didConfigureBackgroundSync = false
    @State private var backgroundSyncScheduler: BackgroundSyncScheduler?

    init() {
        self.environment = AppEnvironment.live()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(\.appEnvironment, environment)
                .environment(\.managedObjectContext, environment.dataController.viewContext)
                .tint(AppSurfaceStyle.accent)
                .task {
                    await configureBackgroundSyncIfNeeded()
                    await environment.syncEngine.runOnce()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        backgroundSyncScheduler?.scheduleTasks()
                    case .active:
                        Task {
                            await environment.syncEngine.runOnce()
                        }
                    default:
                        break
                    }
                }
        }
    }

    @MainActor
    private func configureBackgroundSyncIfNeeded() async {
        guard !didConfigureBackgroundSync else { return }
        didConfigureBackgroundSync = true
        let scheduler = BackgroundSyncScheduler(syncEngine: environment.syncEngine)
        scheduler.registerTasksIfNeeded()
        scheduler.scheduleTasks()
        backgroundSyncScheduler = scheduler
    }
}
