//
//  ReceivingIdempotencyProofsTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

@MainActor
@Suite(.serialized)
struct ReceivingIdempotencyProofsTests {
    private final class MutableDateProvider: @unchecked Sendable, DateProviding {
        var date: Date

        init(_ date: Date) {
            self.date = date
        }

        var now: Date { date }
    }

    private struct StoreHarness {
        let rootURL: URL
        let queueStore: SyncOperationQueueStore
        let purchaseOrderStore: PurchaseOrderStore
        let inventoryStore: InventoryStore
        let ticketStore: TicketStore

        init() {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("receiving_idempotency_proofs_tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            queueStore = SyncOperationQueueStore(fileURL: rootURL.appendingPathComponent("queue.json", isDirectory: false))
            purchaseOrderStore = PurchaseOrderStore(fileURL: rootURL.appendingPathComponent("purchase_orders.json", isDirectory: false))
            inventoryStore = InventoryStore(fileURL: rootURL.appendingPathComponent("inventory.json", isDirectory: false))
            ticketStore = TicketStore()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private actor ReceiveRecorder {
        private(set) var callCount: Int = 0

        func recordCall() {
            callCount += 1
        }
    }

    private actor ReceiveResultQueue {
        private var results: [Result<PurchaseOrderDetail, Error>]

        init(results: [Result<PurchaseOrderDetail, Error>]) {
            self.results = results
        }

        func next() throws -> PurchaseOrderDetail {
            guard !results.isEmpty else {
                throw APIError.serverError(500)
            }

            let nextResult = results.removeFirst()
            return try nextResult.get()
        }
    }

    private struct ShopmonkeyReceiveStub: ShopmonkeyServicing {
        let recorder: ReceiveRecorder
        let receiveQueue: ReceiveResultQueue
        let fallbackDetail: PurchaseOrderDetail

        func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
            .init(id: "vendor_1", name: request.name)
        }

        func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
            .init(id: "part_1", name: request.name)
        }

        func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
        func fetchOrders() async throws -> [OrderSummary] { [] }
        func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
        func searchVendors(name: String) async throws -> [VendorSummary] { [] }
        func fetchOpenTickets() async throws -> [TicketModel] { [] }
        func fetchTicket(id: String) async throws -> TicketModel { TicketModel(id: id, lineItems: []) }
        func fetchInventory() async throws -> [InventoryItem] { [] }
        func testConnection() async throws {}
        func fetchOpenPurchaseOrders() async throws -> [PurchaseOrderSummary] { [] }
        func fetchPurchaseOrder(id: String) async throws -> PurchaseOrderDetail { fallbackDetail }

        func receivePurchaseOrderLineItem(
            purchaseOrderId: String,
            lineItemId: String,
            quantityReceived: Decimal?
        ) async throws -> PurchaseOrderDetail {
            _ = purchaseOrderId
            _ = lineItemId
            _ = quantityReceived
            await recorder.recordCall()
            return try await receiveQueue.next()
        }
    }

    private func seedPurchaseOrderDetail(quantityReceived: Decimal?) -> PurchaseOrderDetail {
        PurchaseOrderDetail(
            id: "po_1",
            vendorName: "Alpha Supply",
            status: "ordered",
            lineItems: [
                PurchaseOrderLineItem(
                    id: "line_1",
                    kind: "part",
                    sku: "SKU-100",
                    partNumber: "BP-100",
                    description: "Brake Pad",
                    quantityOrdered: 4,
                    quantityReceived: quantityReceived,
                    unitCost: 10,
                    extendedCost: 40
                )
            ]
        )
    }

    private func makeViewModel(
        harness: StoreHarness,
        dateProvider: MutableDateProvider,
        shopmonkey: any ShopmonkeyServicing
    ) -> (ReceiveItemViewModel, SyncEngine) {
        let syncEngine = AppEnvironment.makeSyncEngine(
            syncOperationQueue: harness.queueStore,
            dateProvider: dateProvider,
            shopmonkeyAPI: shopmonkey,
            ticketStore: harness.ticketStore,
            inventoryStore: harness.inventoryStore,
            purchaseOrderStore: harness.purchaseOrderStore
        )

        let viewModel = ReceiveItemViewModel(
            purchaseOrderID: "po_1",
            shopmonkeyAPI: shopmonkey,
            purchaseOrderStore: harness.purchaseOrderStore,
            inventoryStore: harness.inventoryStore,
            syncOperationQueue: harness.queueStore,
            syncEngine: syncEngine,
            dateProvider: dateProvider
        )

        return (viewModel, syncEngine)
    }

    @Test func testInventoryIncrementOccursOnlyAfterSuccessfulReceive() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_510_000)
        let dateProvider = MutableDateProvider(now)

        await harness.purchaseOrderStore.savePurchaseOrderDetail(seedPurchaseOrderDetail(quantityReceived: 1))
        await harness.inventoryStore.replaceAll([
            InventoryItem(
                id: "inv_1",
                sku: "SKU-100",
                partNumber: "BP-100",
                description: "Brake Pad",
                price: 10,
                quantityOnHand: 10
            )
        ], at: now)

        let recorder = ReceiveRecorder()
        let receiveQueue = ReceiveResultQueue(results: [
            .failure(APIError.rateLimited),
            .success(seedPurchaseOrderDetail(quantityReceived: 3))
        ])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: receiveQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 3)
        )

        let (viewModel, syncEngine) = makeViewModel(
            harness: harness,
            dateProvider: dateProvider,
            shopmonkey: shopmonkey
        )
        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "BP-100")
        await viewModel.receiveMatchedLine(quantity: 2)

        let inventoryAfterFailedAttempt = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterFailedAttempt[0].quantityOnHand - 10) < 0.001)
        #expect(await recorder.callCount == 1)
        #expect(await harness.queueStore.allOperations().count == 1)

        dateProvider.date = now.addingTimeInterval(120)
        await syncEngine.runOnce()

        let inventoryAfterSuccessfulRetry = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterSuccessfulRetry[0].quantityOnHand - 12) < 0.001)
        #expect(await recorder.callCount == 2)
        #expect(await harness.queueStore.allOperations().isEmpty)
    }

    @Test func testReplayDoesNotDoubleIncrementInventory() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_520_000)
        let dateProvider = MutableDateProvider(now)

        await harness.purchaseOrderStore.savePurchaseOrderDetail(seedPurchaseOrderDetail(quantityReceived: 1))
        await harness.inventoryStore.replaceAll([
            InventoryItem(
                id: "inv_1",
                sku: "SKU-100",
                partNumber: "BP-100",
                description: "Brake Pad",
                price: 10,
                quantityOnHand: 10
            )
        ], at: now)

        let recorder = ReceiveRecorder()
        let receiveQueue = ReceiveResultQueue(results: [
            .success(seedPurchaseOrderDetail(quantityReceived: 2)),
            .success(seedPurchaseOrderDetail(quantityReceived: 2))
        ])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: receiveQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 2)
        )

        let (viewModel, syncEngine) = makeViewModel(
            harness: harness,
            dateProvider: dateProvider,
            shopmonkey: shopmonkey
        )
        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "BP-100")
        await viewModel.receiveMatchedLine(quantity: 1)

        let inventoryAfterFirstSuccess = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterFirstSuccess[0].quantityOnHand - 11) < 0.001)

        let replayPayload = PurchaseOrderLineItemReceivePayload(
            purchaseOrderID: "po_1",
            lineItemID: "line_1",
            quantityReceived: 1,
            priorReceivedQuantity: 1,
            barcode: "BP-100",
            sku: "SKU-100",
            partNumber: "BP-100",
            description: "Brake Pad"
        )
        _ = await harness.queueStore.enqueue(
            SyncOperation(
                id: UUID(),
                type: .receivePurchaseOrderLineItem,
                payloadFingerprint: replayPayload.payloadFingerprint,
                status: .pending,
                retryCount: 0,
                createdAt: dateProvider.now
            )
        )
        await syncEngine.runOnce()

        #expect(await recorder.callCount == 2)
        let inventoryAfterReplay = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterReplay[0].quantityOnHand - 11) < 0.001)
    }
}
