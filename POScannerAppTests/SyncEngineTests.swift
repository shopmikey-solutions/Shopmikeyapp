//
//  SyncEngineTests.swift
//  POScannerAppTests
//

import Foundation
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct SyncEngineTests {
    private struct StoreHarness {
        let fileURL: URL
        let store: SyncOperationQueueStore

        init() {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync_engine_tests")
                .appendingPathComponent("\(UUID().uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
            store = SyncOperationQueueStore(fileURL: fileURL)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    private actor InvocationCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }

        func value() -> Int {
            count
        }
    }

    private func makeOperation(
        id: UUID = UUID(),
        status: OperationStatus = .pending,
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastErrorCode: String? = nil
    ) -> SyncOperation {
        SyncOperation(
            id: id,
            type: .syncInventory,
            payloadFingerprint: "fp-\(id.uuidString.lowercased())",
            status: status,
            retryCount: retryCount,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000),
            lastAttemptAt: nil,
            nextAttemptAt: nextAttemptAt,
            lastErrorCode: lastErrorCode
        )
    }

    @Test func backoffCalculationIsExponentialAndCapped() {
        let policy = SyncRetryPolicy.default
        #expect(SyncEngine.baseBackoffDelay(retryCount: 1, policy: policy) == 30)
        #expect(SyncEngine.baseBackoffDelay(retryCount: 2, policy: policy) == 60)
        #expect(SyncEngine.baseBackoffDelay(retryCount: 3, policy: policy) == 120)
        #expect(SyncEngine.baseBackoffDelay(retryCount: 6, policy: policy) == 600)
        #expect(SyncEngine.baseBackoffDelay(retryCount: 8, policy: policy) == 600)
    }

    @Test func permanentFailureClassificationStopsRetry() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        _ = await harness.store.enqueue(operation)

        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let engine = SyncEngine(
            queueStore: harness.store,
            executor: { _ in .failed(diagnosticCode: DiagnosticCode.authUnauthorized401.rawValue) },
            dateProvider: { now },
            jitterProvider: { 0 }
        )

        await engine.runOnce()

        let persisted = await harness.store.operation(id: operation.id)
        #expect(persisted?.status == .failed)
        #expect(persisted?.retryCount == 0)
        #expect(persisted?.nextAttemptAt == nil)
        #expect(persisted?.lastErrorCode == DiagnosticCode.authUnauthorized401.rawValue)
    }

    @Test func transientFailureIncrementsRetryAndSchedulesNextAttempt() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        _ = await harness.store.enqueue(operation)

        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let engine = SyncEngine(
            queueStore: harness.store,
            executor: { _ in .failed(diagnosticCode: DiagnosticCode.netTimeoutRequest.rawValue) },
            dateProvider: { now },
            jitterProvider: { 0 }
        )

        await engine.runOnce()

        let persisted = await harness.store.operation(id: operation.id)
        #expect(persisted?.status == .pending)
        #expect(persisted?.retryCount == 1)
        #expect(persisted?.lastErrorCode == DiagnosticCode.netTimeoutRequest.rawValue)
        #expect(persisted?.nextAttemptAt == now.addingTimeInterval(30))
    }

    @Test func successRemovesOperationFromQueue() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        _ = await harness.store.enqueue(operation)

        let engine = SyncEngine(
            queueStore: harness.store,
            executor: { _ in .succeeded },
            jitterProvider: { 0 }
        )

        await engine.runOnce()
        let all = await harness.store.allOperations()
        #expect(all.isEmpty)
    }

    @Test func singleFlightPreventsConcurrentRuns() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        _ = await harness.store.enqueue(operation)

        let counter = InvocationCounter()
        let engine = SyncEngine(
            queueStore: harness.store,
            executor: { _ in
                await counter.increment()
                try? await Task.sleep(nanoseconds: 220_000_000)
                return .succeeded
            },
            jitterProvider: { 0 }
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await engine.runOnce() }
            group.addTask { await engine.runOnce() }
        }

        #expect(await counter.value() == 1)
    }
}
