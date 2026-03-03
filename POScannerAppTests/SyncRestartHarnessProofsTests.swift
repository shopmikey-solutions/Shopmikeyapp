//
//  SyncRestartHarnessProofsTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct SyncRestartHarnessProofsTests {
    private struct FixedDateProvider: DateProviding {
        let date: Date
        var now: Date { date }
    }

    private struct StoreHarness {
        let rootURL: URL
        let queueFileURL: URL
        let ticketFileURL: URL
        let inventoryFileURL: URL
        let purchaseOrderFileURL: URL

        init() {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync_restart_harness_proofs_tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            queueFileURL = rootURL.appendingPathComponent("queue.json", isDirectory: false)
            ticketFileURL = rootURL.appendingPathComponent("tickets.json", isDirectory: false)
            inventoryFileURL = rootURL.appendingPathComponent("inventory.json", isDirectory: false)
            purchaseOrderFileURL = rootURL.appendingPathComponent("purchase_orders.json", isDirectory: false)
        }

        func makeQueueStore() -> SyncOperationQueueStore {
            SyncOperationQueueStore(fileURL: queueFileURL)
        }

        func makeTicketStore() -> TicketStore {
            TicketStore(fileURL: ticketFileURL)
        }

        func makeInventoryStore() -> InventoryStore {
            InventoryStore(fileURL: inventoryFileURL)
        }

        func makePurchaseOrderStore() -> PurchaseOrderStore {
            PurchaseOrderStore(fileURL: purchaseOrderFileURL)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private actor CreatePartRecorder {
        struct Invocation {
            var orderID: String
            var serviceID: String
            var request: CreatePartRequest
        }

        private(set) var invocations: [Invocation] = []

        func record(orderID: String, serviceID: String, request: CreatePartRequest) {
            invocations.append(.init(orderID: orderID, serviceID: serviceID, request: request))
        }

        func count() -> Int {
            invocations.count
        }

        func last() -> Invocation? {
            invocations.last
        }
    }

    private actor CreatePartResponseQueue {
        enum Result: Sendable {
            case success(CreatePartResponse)
            case failure(APIError)
        }

        private var results: [Result]

        init(results: [Result]) {
            self.results = results
        }

        func next() throws -> CreatePartResponse {
            guard !results.isEmpty else {
                throw APIError.serverError(500)
            }

            let result = results.removeFirst()
            switch result {
            case .success(let response):
                return response
            case .failure(let error):
                throw error
            }
        }
    }

    private struct ShopmonkeyAddPartStub: ShopmonkeyServicing {
        let recorder: CreatePartRecorder
        let responseQueue: CreatePartResponseQueue

        func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
            .init(id: "vendor_1", name: request.name)
        }

        func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
            await recorder.record(orderID: orderId, serviceID: serviceId, request: request)
            return try await responseQueue.next()
        }

        func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
        func fetchOrders() async throws -> [OrderSummary] { [] }
        func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
        func searchVendors(name: String) async throws -> [VendorSummary] { [] }
        func testConnection() async throws {}
    }

    private func makeEngine(
        queueStore: SyncOperationQueueStore,
        harness: StoreHarness,
        now: Date,
        shopmonkey: any ShopmonkeyServicing
    ) -> SyncEngine {
        AppEnvironment.makeSyncEngine(
            syncOperationQueue: queueStore,
            dateProvider: FixedDateProvider(date: now),
            shopmonkeyAPI: shopmonkey,
            ticketStore: harness.makeTicketStore(),
            inventoryStore: harness.makeInventoryStore(),
            purchaseOrderStore: harness.makePurchaseOrderStore()
        )
    }

    private func makeAddTicketLineItemOperation(
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_777_000_000),
        nextAttemptAt: Date? = nil
    ) -> SyncOperation {
        let payload = TicketLineItemMutationPayload(
            ticketID: "order_1",
            serviceID: "service_1",
            sku: "PAD-001",
            partNumber: "PAD-001",
            description: "Front Brake Pad Set",
            quantity: 2,
            unitPrice: Decimal(string: "99.95"),
            vendorID: "vendor_1",
            mergeMode: .addNewLine
        )

        return SyncOperation(
            id: id,
            type: .addTicketLineItem,
            payloadFingerprint: payload.payloadFingerprint,
            status: .pending,
            retryCount: 0,
            createdAt: createdAt,
            lastAttemptAt: nil,
            nextAttemptAt: nextAttemptAt,
            lastErrorCode: nil
        )
    }

    @Test func testQueuedOperationPersistsAcrossRestart() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let originalStore = harness.makeQueueStore()
        let operation = makeAddTicketLineItemOperation()
        _ = await originalStore.enqueue(operation)

        let restartedStore = harness.makeQueueStore()
        let all = await restartedStore.allOperations()
        #expect(all.count == 1)
        #expect(all.first?.id == operation.id)
        #expect(all.first?.type == .addTicketLineItem)
        #expect(all.first?.payloadFingerprint == operation.payloadFingerprint)
    }

    @Test func testFutureNextAttemptSkipsExecutionAcrossRestart() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeAddTicketLineItemOperation(
            createdAt: Date(timeIntervalSince1970: 1_777_000_100),
            nextAttemptAt: Date(timeIntervalSince1970: 4_102_444_800)
        )

        let queueStore = harness.makeQueueStore()
        _ = await queueStore.enqueue(operation)

        let recorder = CreatePartRecorder()
        let responses = CreatePartResponseQueue(
            results: [.success(.init(id: "part_unused", name: "Front Brake Pad Set"))]
        )
        let shopmonkey = ShopmonkeyAddPartStub(recorder: recorder, responseQueue: responses)

        let firstEngine = makeEngine(
            queueStore: queueStore,
            harness: harness,
            now: Date(timeIntervalSince1970: 1_777_000_120),
            shopmonkey: shopmonkey
        )
        await firstEngine.runOnce()

        #expect(await recorder.count() == 0)
        #expect(await queueStore.operation(id: operation.id)?.status == .pending)

        let restartedStore = harness.makeQueueStore()
        let restartedEngine = makeEngine(
            queueStore: restartedStore,
            harness: harness,
            now: Date(timeIntervalSince1970: 1_777_000_180),
            shopmonkey: shopmonkey
        )
        await restartedEngine.runOnce()

        #expect(await recorder.count() == 0)
        #expect(await restartedStore.operation(id: operation.id)?.status == .pending)
    }

    @Test func testSuccessRemovesOperationAndRestartDoesNotReexecute() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeAddTicketLineItemOperation()
        let queueStore = harness.makeQueueStore()
        _ = await queueStore.enqueue(operation)

        let recorder = CreatePartRecorder()
        let responses = CreatePartResponseQueue(
            results: [.success(.init(id: "part_1", name: "Front Brake Pad Set"))]
        )
        let shopmonkey = ShopmonkeyAddPartStub(recorder: recorder, responseQueue: responses)

        let firstEngine = makeEngine(
            queueStore: queueStore,
            harness: harness,
            now: Date(timeIntervalSince1970: 1_777_001_000),
            shopmonkey: shopmonkey
        )
        await firstEngine.runOnce()

        #expect(await recorder.count() == 1)
        #expect(await queueStore.operation(id: operation.id) == nil)

        let restartedStore = harness.makeQueueStore()
        let restartedEngine = makeEngine(
            queueStore: restartedStore,
            harness: harness,
            now: Date(timeIntervalSince1970: 1_777_001_060),
            shopmonkey: shopmonkey
        )
        await restartedEngine.runOnce()

        #expect(await recorder.count() == 1)
        #expect(await restartedStore.allOperations().isEmpty)
    }

    @Test func testPermanentFailureIsNotRetriedAfterRestart() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let operation = makeAddTicketLineItemOperation()
        let queueStore = harness.makeQueueStore()
        _ = await queueStore.enqueue(operation)

        let recorder = CreatePartRecorder()
        let responses = CreatePartResponseQueue(results: [.failure(.unauthorized)])
        let shopmonkey = ShopmonkeyAddPartStub(recorder: recorder, responseQueue: responses)

        let firstEngine = makeEngine(
            queueStore: queueStore,
            harness: harness,
            now: Date(timeIntervalSince1970: 1_777_002_000),
            shopmonkey: shopmonkey
        )
        await firstEngine.runOnce()

        #expect(await recorder.count() == 1)
        #expect(await queueStore.operation(id: operation.id)?.status == .failed)
        #expect(await queueStore.operation(id: operation.id)?.lastErrorCode == DiagnosticCode.authUnauthorized401.rawValue)

        let restartedStore = harness.makeQueueStore()
        let restartedEngine = makeEngine(
            queueStore: restartedStore,
            harness: harness,
            now: Date(timeIntervalSince1970: 1_777_002_060),
            shopmonkey: shopmonkey
        )
        await restartedEngine.runOnce()

        #expect(await recorder.count() == 1)
        #expect(await restartedStore.operation(id: operation.id)?.status == .failed)
    }
}
