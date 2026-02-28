//
//  BackgroundSyncScheduler.swift
//  POScannerApp
//

import Foundation
import os
import ShopmikeyCoreSync

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@MainActor
final class BackgroundSyncScheduler {
    static let refreshTaskIdentifier = "com.mikey.POScannerApp.sync.refresh"
    static let processingTaskIdentifier = "com.mikey.POScannerApp.sync.processing"

    private static let logger = Logger(
        subsystem: "com.mikey.POScannerApp",
        category: "Sync.Background"
    )

    private let syncEngine: SyncEngine
    private var didRegister = false

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
    }

    func registerTasksIfNeeded() {
#if canImport(BackgroundTasks)
        guard !didRegister else { return }
        didRegister = true

        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handleAppRefreshTask(refreshTask)
            }
        }

        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handleProcessingTask(processingTask)
            }
        }

        Self.logger.info(
            "BG tasks registered. refresh=\(refreshRegistered, privacy: .public) processing=\(processingRegistered, privacy: .public)"
        )
#endif
    }

    func scheduleTasks() {
#if canImport(BackgroundTasks)
        scheduleAppRefresh()
        scheduleProcessingTask()
#endif
    }

#if canImport(BackgroundTasks)
    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(120)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.logger.error("Failed to schedule app refresh task: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(180)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.logger.error("Failed to schedule processing task: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleAppRefreshTask(_ task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let runner = Task { [syncEngine] in
            await syncEngine.runOnce()
        }

        task.expirationHandler = {
            runner.cancel()
        }

        Task { @MainActor in
            _ = await runner.result
            task.setTaskCompleted(success: !runner.isCancelled)
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        scheduleProcessingTask()
        let runner = Task { [syncEngine] in
            await syncEngine.runOnce()
        }

        task.expirationHandler = {
            runner.cancel()
        }

        Task { @MainActor in
            _ = await runner.result
            task.setTaskCompleted(success: !runner.isCancelled)
        }
    }
#endif
}
