//
//  OfflineToOnlineSubmissionTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct OfflineToOnlineSubmissionTests {
    private struct StoreHarness {
        let fileURL: URL
        let store: SyncOperationQueueStore

        init() {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("offline_to_online_submission_tests")
                .appendingPathComponent("\(UUID().uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
            store = SyncOperationQueueStore(fileURL: fileURL)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    private actor SequenceExecutor {
        private var results: [SyncExecutionResult]
        private(set) var invocationCount = 0

        init(results: [SyncExecutionResult]) {
            self.results = results
        }

        func execute(_ operation: SyncOperation) -> SyncExecutionResult {
            invocationCount += 1
            guard !results.isEmpty else { return .succeeded }
            return results.removeFirst()
        }
    }

    @Test func queuedSubmissionRetriesOfflineThenSucceedsOnline() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = SyncOperation(
            id: UUID(),
            type: .submitPurchaseOrder,
            payloadFingerprint: "submission-fingerprint",
            status: .pending,
            retryCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000),
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            lastErrorCode: nil
        )
        _ = await harness.store.enqueue(operation)

        let executor = SequenceExecutor(results: [
            .failed(diagnosticCode: DiagnosticCode.netConnectivityUnreachable.rawValue),
            .succeeded
        ])
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let engine = SyncEngine(
            queueStore: harness.store,
            executor: { operation in
                await executor.execute(operation)
            },
            dateProvider: { now },
            jitterProvider: { 0 }
        )

        await engine.runOnce()

        let afterOfflineAttempt = await harness.store.operation(id: operation.id)
        #expect(afterOfflineAttempt?.status == .pending)
        #expect(afterOfflineAttempt?.retryCount == 1)

        await harness.store.markPendingForRetry(
            id: operation.id,
            nextAttemptAt: now,
            errorCode: nil
        )

        await engine.runOnce()

        let remaining = await harness.store.allOperations()
        #expect(remaining.isEmpty)
        #expect(await executor.invocationCount == 2)
    }
}
