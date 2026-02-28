//
//  SyncEngineResilienceTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct SyncEngineResilienceTests {
    private struct StoreHarness {
        let fileURL: URL
        let store: SyncOperationQueueStore

        init() {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync_engine_resilience_tests")
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
        type: OperationType = .syncInventory
    ) -> SyncOperation {
        SyncOperation(
            id: id,
            type: type,
            payloadFingerprint: "fp-\(id.uuidString.lowercased())",
            status: .pending,
            retryCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000),
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            lastErrorCode: nil
        )
    }

    @Test func transientFailureSchedulesNextAttempt() async {
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
        #expect(persisted?.nextAttemptAt == now.addingTimeInterval(30))
    }

    @Test func permanentFailureStopsRetries() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        _ = await harness.store.enqueue(operation)

        let engine = SyncEngine(
            queueStore: harness.store,
            executor: { _ in .failed(diagnosticCode: DiagnosticCode.submitValidatePayload.rawValue) },
            jitterProvider: { 0 }
        )

        await engine.runOnce()

        let persisted = await harness.store.operation(id: operation.id)
        #expect(persisted?.status == .failed)
        #expect(persisted?.retryCount == 0)
        #expect(persisted?.nextAttemptAt == nil)
        #expect(persisted?.lastErrorCode == DiagnosticCode.submitValidatePayload.rawValue)
    }

    @Test func runOnceSingleFlightPreventsConcurrentExecution() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeOperation()
        _ = await harness.store.enqueue(operation)

        let counter = InvocationCounter()
        let engine = SyncEngine(
            queueStore: harness.store,
            executor: { _ in
                await counter.increment()
                try? await Task.sleep(nanoseconds: 200_000_000)
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
