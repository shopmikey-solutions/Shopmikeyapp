//
//  PurchaseOrderReceivingFlowTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

@MainActor
@Suite(.serialized)
struct PurchaseOrderReceivingFlowTests {
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
                .appendingPathComponent("purchase_order_receiving_flow_tests", isDirectory: true)
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
        struct Call: Equatable {
            var purchaseOrderID: String
            var lineItemID: String
            var quantityReceived: Decimal?
        }

        private(set) var calls: [Call] = []

        func append(_ call: Call) {
            calls.append(call)
        }

        func count() -> Int { calls.count }

        func last() -> Call? { calls.last }
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
            let next = results.removeFirst()
            return try next.get()
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

        func fetchPurchaseOrder(id: String) async throws -> PurchaseOrderDetail {
            fallbackDetail
        }

        func receivePurchaseOrderLineItem(
            purchaseOrderId: String,
            lineItemId: String,
            quantityReceived: Decimal?
        ) async throws -> PurchaseOrderDetail {
            await recorder.append(
                .init(
                    purchaseOrderID: purchaseOrderId,
                    lineItemID: lineItemId,
                    quantityReceived: quantityReceived
                )
            )
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
    ) -> ReceiveItemViewModel {
        let syncEngine = AppEnvironment.makeSyncEngine(
            syncOperationQueue: harness.queueStore,
            dateProvider: dateProvider,
            shopmonkeyAPI: shopmonkey,
            ticketStore: harness.ticketStore,
            inventoryStore: harness.inventoryStore,
            purchaseOrderStore: harness.purchaseOrderStore
        )

        return ReceiveItemViewModel(
            purchaseOrderID: "po_1",
            shopmonkeyAPI: shopmonkey,
            purchaseOrderStore: harness.purchaseOrderStore,
            inventoryStore: harness.inventoryStore,
            syncOperationQueue: harness.queueStore,
            syncEngine: syncEngine,
            dateProvider: dateProvider
        )
    }

    @Test func successfulReceiveUpdatesPOAndInventoryAndClearsQueue() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_000_000)
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
        let resultQueue = ReceiveResultQueue(results: [.success(seedPurchaseOrderDetail(quantityReceived: 2))])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: resultQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 2)
        )

        let viewModel = makeViewModel(harness: harness, dateProvider: dateProvider, shopmonkey: shopmonkey)
        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "BP-100")
        await viewModel.receiveMatchedLine(quantity: 1)

        #expect(await recorder.count() == 1)
        let call = await recorder.last()
        #expect(call?.purchaseOrderID == "po_1")
        #expect(call?.lineItemID == "line_1")
        #expect(NSDecimalNumber(decimal: call?.quantityReceived ?? 0).doubleValue == 1)

        let updatedDetail = await harness.purchaseOrderStore.loadPurchaseOrderDetail(id: "po_1")
        #expect(NSDecimalNumber(decimal: updatedDetail?.lineItems.first?.quantityReceived ?? 0).doubleValue == 2)

        let inventoryItems = await harness.inventoryStore.allItems()
        #expect(inventoryItems.count == 1)
        #expect(abs(inventoryItems[0].quantityOnHand - 11) < 0.001)

        #expect(await harness.queueStore.allOperations().isEmpty)
        #expect(viewModel.receiveState == .succeeded)
        #expect(viewModel.matchState == .idle)
        #expect(viewModel.scannedCode == nil)
    }

    @Test func transientFailureQueuesAndLaterSyncRunIncrementsInventoryOnSuccess() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_100_000)
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
        let resultQueue = ReceiveResultQueue(results: [
            .failure(APIError.rateLimited),
            .success(seedPurchaseOrderDetail(quantityReceived: 3))
        ])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: resultQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 3)
        )

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

        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "BP-100")
        await viewModel.receiveMatchedLine(quantity: 2)

        #expect(await recorder.count() == 1)
        #expect(viewModel.receiveState == .queued(diagnosticCode: DiagnosticCode.netRate429.rawValue))
        #expect(viewModel.matchState == .idle)
        #expect(viewModel.scannedCode == nil)

        let queuedOperationID = try? #require(viewModel.lastOperationID)
        if let queuedOperationID {
            let queued = await harness.queueStore.operation(id: queuedOperationID)
            #expect(queued?.status == .pending)
            #expect(queued?.retryCount == 1)
            #expect(queued?.lastErrorCode == DiagnosticCode.netRate429.rawValue)
        }

        let inventoryAfterFailure = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterFailure[0].quantityOnHand - 10) < 0.001)

        dateProvider.date = now.addingTimeInterval(120)
        await syncEngine.runOnce()

        #expect(await recorder.count() == 2)
        #expect(await harness.queueStore.allOperations().isEmpty)

        let updatedDetail = await harness.purchaseOrderStore.loadPurchaseOrderDetail(id: "po_1")
        #expect(NSDecimalNumber(decimal: updatedDetail?.lineItems.first?.quantityReceived ?? 0).doubleValue == 3)

        let inventoryAfterRetrySuccess = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterRetrySuccess[0].quantityOnHand - 12) < 0.001)
    }

    @Test func replayedReceivePayloadDoesNotDoubleIncrementInventory() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_120_000)
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
        let resultQueue = ReceiveResultQueue(results: [
            .success(seedPurchaseOrderDetail(quantityReceived: 2)),
            .success(seedPurchaseOrderDetail(quantityReceived: 2))
        ])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: resultQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 2)
        )

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

        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "BP-100")
        await viewModel.receiveMatchedLine(quantity: 1)

        let inventoryAfterFirstReceive = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterFirstReceive[0].quantityOnHand - 11) < 0.001)
        #expect(await recorder.count() == 1)

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

        #expect(await recorder.count() == 2)
        let inventoryAfterReplay = await harness.inventoryStore.allItems()
        #expect(abs(inventoryAfterReplay[0].quantityOnHand - 11) < 0.001)
    }

    @Test func noMatchDoesNotCallAPIOrQueueOperation() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_200_000)
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
        let resultQueue = ReceiveResultQueue(results: [.success(seedPurchaseOrderDetail(quantityReceived: 2))])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: resultQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 2)
        )

        let viewModel = makeViewModel(harness: harness, dateProvider: dateProvider, shopmonkey: shopmonkey)
        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "UNKNOWN-CODE")

        #expect(viewModel.matchState == .noMatch)

        await viewModel.receiveMatchedLine(quantity: 1)

        #expect(await recorder.count() == 0)
        #expect(await harness.queueStore.allOperations().isEmpty)

        let inventoryItems = await harness.inventoryStore.allItems()
        #expect(abs(inventoryItems[0].quantityOnHand - 10) < 0.001)
    }

    @Test func overReceiveIsBlockedBeforeAPIAndQueue() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_300_000)
        let dateProvider = MutableDateProvider(now)

        await harness.purchaseOrderStore.savePurchaseOrderDetail(seedPurchaseOrderDetail(quantityReceived: 3))
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
        let resultQueue = ReceiveResultQueue(results: [.success(seedPurchaseOrderDetail(quantityReceived: 4))])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: resultQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 4)
        )

        let viewModel = makeViewModel(harness: harness, dateProvider: dateProvider, shopmonkey: shopmonkey)
        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "BP-100")
        await viewModel.receiveMatchedLine(quantity: 2)

        #expect(await recorder.count() == 0)
        #expect(await harness.queueStore.allOperations().isEmpty)
        #expect(viewModel.receiveState == .failed(diagnosticCode: nil))
        #expect(viewModel.receiveMessage == "Quantity exceeds remaining amount (1).")
    }

    @Test func fullyReceivedLineCannotBeReceived() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_773_400_000)
        let dateProvider = MutableDateProvider(now)

        await harness.purchaseOrderStore.savePurchaseOrderDetail(seedPurchaseOrderDetail(quantityReceived: 4))
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
        let resultQueue = ReceiveResultQueue(results: [.success(seedPurchaseOrderDetail(quantityReceived: 5))])
        let shopmonkey = ShopmonkeyReceiveStub(
            recorder: recorder,
            receiveQueue: resultQueue,
            fallbackDetail: seedPurchaseOrderDetail(quantityReceived: 5)
        )

        let viewModel = makeViewModel(harness: harness, dateProvider: dateProvider, shopmonkey: shopmonkey)
        await viewModel.loadInitialDetail()
        await viewModel.lookup(scannedCode: "BP-100")

        #expect(viewModel.canReceiveMatchedLine == false)
        await viewModel.receiveMatchedLine(quantity: 1)

        #expect(await recorder.count() == 0)
        #expect(await harness.queueStore.allOperations().isEmpty)
        #expect(viewModel.receiveState == .failed(diagnosticCode: nil))
        #expect(viewModel.receiveMessage == "Line fully received.")
    }
}
