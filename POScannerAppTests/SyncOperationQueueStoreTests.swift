//
//  SyncOperationQueueStoreTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct SyncOperationQueueStoreTests {
    private struct StoreHarness {
        let fileURL: URL
        let store: SyncOperationQueueStore

        init(maxOperations: Int = 1_000) {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync_operation_queue_tests")
                .appendingPathComponent("\(UUID().uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
            store = SyncOperationQueueStore(fileURL: fileURL, maxOperations: maxOperations)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        func makeReloadedStore() -> SyncOperationQueueStore {
            SyncOperationQueueStore(fileURL: fileURL)
        }
    }

    private func makeOperation(
        id: UUID = UUID(),
        fingerprint: String = "fp-1",
        status: OperationStatus = .pending,
        retryCount: Int = 0
    ) -> SyncOperation {
        SyncOperation(
            id: id,
            type: .submitPurchaseOrder,
            payloadFingerprint: fingerprint,
            status: status,
            retryCount: retryCount,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000),
            lastAttemptAt: nil
        )
    }

    @Test func enqueuePersistsAcrossReinitialization() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        _ = await harness.store.enqueue(operation)

        let reloadedStore = harness.makeReloadedStore()
        let all = await reloadedStore.allOperations()
        #expect(all.count == 1)
        #expect(all.first?.id == operation.id)
        #expect(all.first?.status == .pending)
    }

    @Test func markTransitionsAreDeterministic() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        let operationID = await harness.store.enqueue(operation)

        await harness.store.markInProgress(id: operationID)
        #expect(await harness.store.operation(id: operationID)?.status == .inProgress)

        await harness.store.markFailed(id: operationID)
        #expect(await harness.store.operation(id: operationID)?.status == .failed)

        await harness.store.markSucceeded(id: operationID)
        #expect(await harness.store.operation(id: operationID)?.status == .succeeded)
    }

    @Test func incrementRetryIncrementsCorrectly() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        let operationID = await harness.store.enqueue(operation)

        await harness.store.incrementRetry(id: operationID)
        await harness.store.incrementRetry(id: operationID)

        #expect(await harness.store.operation(id: operationID)?.retryCount == 2)
    }

    @Test func removeDeletesOnlyTargetedOperation() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let first = makeOperation(fingerprint: "fp-first")
        let second = makeOperation(fingerprint: "fp-second")

        _ = await harness.store.enqueue(first)
        _ = await harness.store.enqueue(second)
        await harness.store.remove(id: first.id)

        let all = await harness.store.allOperations()
        #expect(all.count == 1)
        #expect(all.first?.id == second.id)
    }

    @Test func clearResetsQueue() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        _ = await harness.store.enqueue(makeOperation())
        await harness.store.clear()

        #expect(await harness.store.allOperations().isEmpty)
    }

    @Test func invalidJSONRecoversSafely() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let directoryURL = harness.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let invalidData = Data("not-json".utf8)
        try? invalidData.write(to: harness.fileURL, options: .atomic)

        let reloadedStore = harness.makeReloadedStore()
        #expect(await reloadedStore.allOperations().isEmpty)

        _ = await reloadedStore.enqueue(makeOperation(fingerprint: "fp-recovered"))
        #expect(await reloadedStore.allOperations().count == 1)
    }
}
