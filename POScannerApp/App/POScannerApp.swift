//
//  POScannerApp.swift
//  POScannerApp
//
//  Created by Michael Bordeaux on 2/15/26.
//

import SwiftUI

@main
struct POScannerApp: App {
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var appNotificationDelegate
    private let environment: AppEnvironment

    init() {
        self.environment = AppEnvironment.live()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(\.appEnvironment, environment)
                .environment(\.managedObjectContext, environment.dataController.viewContext)
                .tint(AppSurfaceStyle.accent)
        }
    }
}
