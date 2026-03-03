//
//  TicketAddPartProofsTests.swift
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
struct TicketAddPartProofsTests {
    private struct FixedDateProvider: DateProviding {
        let date: Date
        var now: Date { date }
    }

    private struct StoreHarness {
        let rootURL: URL
        let queueStore: SyncOperationQueueStore
        let ticketStore: TicketStore
        let inventoryStore: InventoryStore
        let purchaseOrderStore: PurchaseOrderStore

        init() {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ticket_add_part_proofs_tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            queueStore = SyncOperationQueueStore(fileURL: rootURL.appendingPathComponent("queue.json", isDirectory: false))
            ticketStore = TicketStore(fileURL: rootURL.appendingPathComponent("tickets.json", isDirectory: false))
            inventoryStore = InventoryStore(fileURL: rootURL.appendingPathComponent("inventory.json", isDirectory: false))
            purchaseOrderStore = PurchaseOrderStore(fileURL: rootURL.appendingPathComponent("purchase_orders.json", isDirectory: false))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private actor AddPartRecorder {
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

    private struct ShopmonkeyAddPartStub: ShopmonkeyServicing {
        let recorder: AddPartRecorder
        let servicesByOrderID: [String: [ServiceSummary]]
        let servicesError: Error?
        let createPartBehavior: @Sendable (CreatePartRequest) async throws -> CreatePartResponse

        func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
            .init(id: "vendor_1", name: request.name)
        }

        func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
            await recorder.record(orderID: orderId, serviceID: serviceId, request: request)
            return try await createPartBehavior(request)
        }

        func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse {
            _ = orderId
            _ = serviceId
            _ = request
            throw APIError.serverError(501)
        }

        func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse {
            _ = orderId
            _ = serviceId
            _ = request
            throw APIError.serverError(501)
        }

        func createPurchaseOrder(_ request: CreatePurchaseOrderRequest) async throws -> CreatePurchaseOrderResponse {
            _ = request
            throw APIError.serverError(501)
        }

        func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
        func fetchOpenPurchaseOrders() async throws -> [PurchaseOrderSummary] { [] }
        func fetchPurchaseOrder(id: String) async throws -> PurchaseOrderDetail {
            PurchaseOrderDetail(id: id, lineItems: [])
        }

        func receivePurchaseOrderLineItem(
            purchaseOrderId: String,
            lineItemId: String,
            quantityReceived: Decimal?
        ) async throws -> PurchaseOrderDetail {
            _ = purchaseOrderId
            _ = lineItemId
            _ = quantityReceived
            throw APIError.serverError(501)
        }

        func fetchOrders() async throws -> [OrderSummary] { [] }

        func fetchServices(orderId: String) async throws -> [ServiceSummary] {
            if let servicesError {
                throw servicesError
            }
            return servicesByOrderID[orderId] ?? []
        }

        func fetchOpenTickets() async throws -> [TicketModel] { [] }
        func fetchTicket(id: String) async throws -> TicketModel {
            TicketModel(id: id, lineItems: [])
        }

        func addPartLineItem(
            toTicketId ticketId: String,
            sku: String?,
            partNumber: String?,
            description: String,
            quantity: Decimal,
            unitPrice: Decimal?
        ) async throws -> TicketLineItem {
            _ = ticketId
            _ = sku
            _ = partNumber
            _ = description
            _ = quantity
            _ = unitPrice
            throw APIError.serverError(501)
        }

        func fetchInventory() async throws -> [InventoryItem] { [] }
        func searchVendors(name: String) async throws -> [VendorSummary] { _ = name; return [] }
        func testConnection() async throws {}
    }

    private func makeSyncEngine(
        harness: StoreHarness,
        now: Date,
        shopmonkey: any ShopmonkeyServicing
    ) -> SyncEngine {
        AppEnvironment.makeSyncEngine(
            syncOperationQueue: harness.queueStore,
            dateProvider: FixedDateProvider(date: now),
            shopmonkeyAPI: shopmonkey,
            ticketStore: harness.ticketStore,
            inventoryStore: harness.inventoryStore,
            purchaseOrderStore: harness.purchaseOrderStore
        )
    }

    private func prepareLookupViewModel(
        harness: StoreHarness,
        now: Date,
        shopmonkey: any ShopmonkeyServicing,
        selectedServiceID: String?
    ) async -> InventoryLookupViewModel {
        await harness.inventoryStore.replaceAll(
            [
                InventoryItem(
                    id: "inv_1",
                    sku: "PAD-001",
                    partNumber: "PAD-001",
                    description: "Front Brake Pad Set",
                    price: 99.95,
                    quantityOnHand: 10,
                    vendorId: "vendor_1"
                )
            ],
            at: now
        )

        _ = await harness.ticketStore.saveOpenTicketsPage(
            page: 0,
            tickets: [
                TicketModel(
                    id: "order_1",
                    number: "RO-1",
                    status: "Open",
                    lineItems: []
                )
            ],
            pageSize: 50,
            refreshedAt: now
        )
        await harness.ticketStore.setActiveTicketID("order_1")
        await harness.ticketStore.setSelectedServiceID(selectedServiceID, forTicketID: "order_1")

        let viewModel = InventoryLookupViewModel(
            inventoryStore: harness.inventoryStore,
            ticketStore: harness.ticketStore,
            purchaseOrderStore: harness.purchaseOrderStore,
            syncOperationQueue: harness.queueStore,
            syncEngine: makeSyncEngine(harness: harness, now: now, shopmonkey: shopmonkey),
            dateProvider: FixedDateProvider(date: now),
            serviceResolver: { orderID in
                try await shopmonkey.fetchServices(orderId: orderID)
            }
        )
        await viewModel.lookup(scannedCode: "PAD-001")
        return viewModel
    }

    @Test func testAddPartIsBlockedWhenServiceSelectionMissingOffline() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = AddPartRecorder()
        let shopmonkey = ShopmonkeyAddPartStub(
            recorder: recorder,
            servicesByOrderID: [:],
            servicesError: URLError(.notConnectedToInternet),
            createPartBehavior: { request in
                .init(id: "part_unused", name: request.name)
            }
        )
        let now = Date(timeIntervalSince1970: 1_774_100_000)
        let viewModel = await prepareLookupViewModel(
            harness: harness,
            now: now,
            shopmonkey: shopmonkey,
            selectedServiceID: nil
        )

        await viewModel.addMatchedItemToTicket(ticketID: "order_1", mergeMode: .addNewLine)

        #expect(viewModel.ticketMutationState == .failed(diagnosticCode: nil))
        #expect(viewModel.ticketMutationMessage?.contains("offline") == true)
        #expect(viewModel.lastTicketMutationOperationID == nil)
        #expect(await harness.queueStore.allOperations().isEmpty)
        #expect(await recorder.count() == 0)
    }

    @Test func testAddPartExecutorUsesOrderAndServiceIDsFromOperation() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = AddPartRecorder()
        let shopmonkey = ShopmonkeyAddPartStub(
            recorder: recorder,
            servicesByOrderID: [:],
            servicesError: nil,
            createPartBehavior: { request in
                .init(id: "created_part_1", name: request.name)
            }
        )
        let now = Date(timeIntervalSince1970: 1_774_110_000)
        await harness.ticketStore.save(ticket: TicketModel(id: "order_1", status: "Open", lineItems: []))

        let payload = TicketLineItemMutationPayload(
            ticketID: "order_1",
            serviceID: "service_1",
            sku: "PAD-001",
            partNumber: "PAD-001",
            description: "Front Brake Pad Set",
            quantity: 2,
            unitPrice: 99.95,
            vendorID: "vendor_1",
            mergeMode: .addNewLine
        )
        let operation = SyncOperation(
            id: UUID(),
            type: .addTicketLineItem,
            payloadFingerprint: payload.payloadFingerprint,
            status: .pending,
            retryCount: 0,
            createdAt: now
        )
        _ = await harness.queueStore.enqueue(operation)

        let syncEngine = makeSyncEngine(harness: harness, now: now, shopmonkey: shopmonkey)
        await syncEngine.runOnce()

        #expect(await recorder.count() == 1)
        let invocation = await recorder.last()
        #expect(invocation?.orderID == "order_1")
        #expect(invocation?.serviceID == "service_1")
        #expect(invocation?.request.partNumber == "PAD-001")
        #expect(invocation?.request.quantity == 2)
        #expect(await harness.queueStore.operation(id: operation.id) == nil)
    }

    @Test func testAddPartIsNotReexecutedAfterSuccessWhenEngineRunsAgain() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = AddPartRecorder()
        let shopmonkey = ShopmonkeyAddPartStub(
            recorder: recorder,
            servicesByOrderID: [:],
            servicesError: nil,
            createPartBehavior: { request in
                .init(id: "created_part_2", name: request.name)
            }
        )
        let now = Date(timeIntervalSince1970: 1_774_120_000)
        await harness.ticketStore.save(ticket: TicketModel(id: "order_2", status: "Open", lineItems: []))

        let payload = TicketLineItemMutationPayload(
            ticketID: "order_2",
            serviceID: "service_2",
            sku: "ROTOR-001",
            partNumber: "ROTOR-001",
            description: "Rotor",
            quantity: 1,
            unitPrice: 75,
            vendorID: "vendor_2",
            mergeMode: .addNewLine
        )
        let operation = SyncOperation(
            id: UUID(),
            type: .addTicketLineItem,
            payloadFingerprint: payload.payloadFingerprint,
            status: .pending,
            retryCount: 0,
            createdAt: now
        )
        _ = await harness.queueStore.enqueue(operation)

        let syncEngine = makeSyncEngine(harness: harness, now: now, shopmonkey: shopmonkey)
        await syncEngine.runOnce()
        await syncEngine.runOnce()

        #expect(await recorder.count() == 1)
        #expect(await harness.queueStore.allOperations().isEmpty)
    }
}
