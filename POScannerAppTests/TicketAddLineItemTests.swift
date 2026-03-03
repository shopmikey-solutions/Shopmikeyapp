//
//  TicketAddLineItemTests.swift
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
struct TicketAddLineItemTests {
    private struct FixedDateProvider: DateProviding {
        let date: Date
        var now: Date { date }
    }

    private struct StoreHarness {
        let queueFileURL: URL
        let ticketFileURL: URL
        let queueStore: SyncOperationQueueStore
        let ticketStore: TicketStore
        let inventoryStore: InventoryStore
        let purchaseOrderStore: PurchaseOrderStore

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ticket_add_line_item_tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            queueFileURL = root.appendingPathComponent("queue.json", isDirectory: false)
            ticketFileURL = root.appendingPathComponent("tickets.json", isDirectory: false)
            queueStore = SyncOperationQueueStore(fileURL: queueFileURL)
            ticketStore = TicketStore(fileURL: ticketFileURL)
            inventoryStore = InventoryStore()
            purchaseOrderStore = PurchaseOrderStore()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
        }
    }

    private actor RequestRecorder {
        struct CreatePartInvocation {
            var orderID: String
            var serviceID: String
            var request: CreatePartRequest
        }

        private(set) var createPartInvocations: [CreatePartInvocation] = []

        func appendCreatePart(_ invocation: CreatePartInvocation) {
            createPartInvocations.append(invocation)
        }

        func lastCreatePart() -> CreatePartInvocation? {
            createPartInvocations.last
        }

        func createPartCount() -> Int {
            createPartInvocations.count
        }
    }

    private struct ShopmonkeyStub: ShopmonkeyServicing {
        let recorder: RequestRecorder
        let servicesByOrderID: [String: [ServiceSummary]]
        let servicesError: Error?
        let createPartBehavior: @Sendable (CreatePartRequest) async throws -> CreatePartResponse

        func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
            .init(id: "vendor_1", name: request.name)
        }

        func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
            await recorder.appendCreatePart(
                .init(orderID: orderId, serviceID: serviceId, request: request)
            )
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

    private func prepareLookupViewModel(
        harness: StoreHarness,
        shopmonkey: any ShopmonkeyServicing,
        now: Date,
        selectedServiceID: String? = nil
    ) async -> InventoryLookupViewModel {
        await harness.inventoryStore.replaceAll(
            [
                InventoryItem(
                    id: "inv_1",
                    sku: "PAD-001",
                    partNumber: "PAD-001",
                    description: "Front Brake Pad Set",
                    price: 99.95,
                    quantityOnHand: 12,
                    vendorId: "vendor_1"
                )
            ],
            at: now
        )

        _ = await harness.ticketStore.saveOpenTicketsPage(
            page: 0,
            tickets: [
                TicketModel(
                    id: "ticket_1",
                    number: "RO-1001",
                    status: "Open",
                    lineItems: []
                )
            ],
            pageSize: 50,
            refreshedAt: now
        )
        await harness.ticketStore.setActiveTicketID("ticket_1")
        await harness.ticketStore.setSelectedServiceID(selectedServiceID, forTicketID: "ticket_1")

        let engine = AppEnvironment.makeSyncEngine(
            syncOperationQueue: harness.queueStore,
            dateProvider: FixedDateProvider(date: now),
            shopmonkeyAPI: shopmonkey,
            ticketStore: harness.ticketStore,
            inventoryStore: harness.inventoryStore,
            purchaseOrderStore: harness.purchaseOrderStore
        )

        let viewModel = InventoryLookupViewModel(
            inventoryStore: harness.inventoryStore,
            ticketStore: harness.ticketStore,
            syncOperationQueue: harness.queueStore,
            syncEngine: engine,
            dateProvider: FixedDateProvider(date: now),
            serviceResolver: { orderID in
                try await shopmonkey.fetchServices(orderId: orderID)
            }
        )
        await viewModel.lookup(scannedCode: "PAD-001")
        return viewModel
    }

    @Test func addToTicketSuccessUsesServiceScopedCreatePartAndRemovesQueuedOperation() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            servicesByOrderID: ["ticket_1": [.init(id: "service_1", name: "Brakes")]],
            servicesError: nil,
            createPartBehavior: { request in
                .init(id: "part_1", name: request.name)
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_000)
        let viewModel = await prepareLookupViewModel(
            harness: harness,
            shopmonkey: shopmonkey,
            now: now,
            selectedServiceID: "service_1"
        )
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        let invocation = await recorder.lastCreatePart()
        #expect(invocation?.orderID == "ticket_1")
        #expect(invocation?.serviceID == "service_1")
        #expect(invocation?.request.name == "Front Brake Pad Set")
        #expect(invocation?.request.partNumber == "PAD-001")
        #expect(invocation?.request.vendorId == "vendor_1")
        #expect(invocation?.request.quantity == 1)
        #expect(viewModel.ticketMutationState == .succeeded)

        let operationID = try? #require(viewModel.lastTicketMutationOperationID)
        if let operationID {
            #expect(await harness.queueStore.operation(id: operationID) == nil)
        }

        let ticket = await harness.ticketStore.loadTicket(id: "ticket_1")
        #expect(ticket?.lineItems.count == 1)
        #expect(ticket?.lineItems.first?.id == "part_1")
    }

    @Test func oneServiceAutoSelectsAndCachesServiceContext() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            servicesByOrderID: ["ticket_1": [.init(id: "svc_auto", name: "Default Service")]],
            servicesError: nil,
            createPartBehavior: { request in
                .init(id: "part_auto", name: request.name)
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_050)
        let viewModel = await prepareLookupViewModel(harness: harness, shopmonkey: shopmonkey, now: now)
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        #expect(viewModel.ticketMutationState == .succeeded)
        #expect(await harness.ticketStore.selectedServiceID(forTicketID: "ticket_1") == "svc_auto")
        let invocation = await recorder.lastCreatePart()
        #expect(invocation?.serviceID == "svc_auto")
    }

    @Test func multipleServicesRequiresExplicitSelectionAndBlocksQueue() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            servicesByOrderID: [
                "ticket_1": [
                    .init(id: "svc_1", name: "Brakes"),
                    .init(id: "svc_2", name: "Alignment")
                ]
            ],
            servicesError: nil,
            createPartBehavior: { request in
                .init(id: "part_unused", name: request.name)
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_075)
        let viewModel = await prepareLookupViewModel(harness: harness, shopmonkey: shopmonkey, now: now)
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        #expect(viewModel.ticketMutationState == .failed(diagnosticCode: nil))
        #expect(viewModel.ticketMutationMessage?.contains("Multiple services") == true)
        #expect(viewModel.lastTicketMutationOperationID == nil)
        #expect(await recorder.createPartCount() == 0)
        #expect(await harness.queueStore.allOperations().isEmpty)
    }

    @Test func offlineWithoutCachedServiceBlocksMutation() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            servicesByOrderID: [:],
            servicesError: URLError(.notConnectedToInternet),
            createPartBehavior: { request in
                .init(id: "part_unused", name: request.name)
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_100)
        let viewModel = await prepareLookupViewModel(harness: harness, shopmonkey: shopmonkey, now: now)
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        #expect(viewModel.ticketMutationState == .failed(diagnosticCode: nil))
        #expect(viewModel.ticketMutationMessage?.contains("cached service") == true)
        #expect(viewModel.lastTicketMutationOperationID == nil)
        #expect(await recorder.createPartCount() == 0)
        #expect(await harness.queueStore.allOperations().isEmpty)
    }

    @Test func serviceEndpointNotFoundIsTreatedAsNoServices() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            servicesByOrderID: [:],
            servicesError: APIError.serverError(404),
            createPartBehavior: { request in
                .init(id: "part_unused", name: request.name)
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_125)
        let viewModel = await prepareLookupViewModel(harness: harness, shopmonkey: shopmonkey, now: now)
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        #expect(viewModel.ticketMutationState == .failed(diagnosticCode: nil))
        #expect(viewModel.ticketMutationMessage?.contains("No services found") == true)
        #expect(viewModel.lastTicketMutationOperationID == nil)
        #expect(await recorder.createPartCount() == 0)
        #expect(await harness.queueStore.allOperations().isEmpty)
    }

    @Test func transientFailureLeavesOperationQueuedForRetry() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            servicesByOrderID: ["ticket_1": [.init(id: "service_1", name: "Brakes")]],
            servicesError: nil,
            createPartBehavior: { _ in
                throw APIError.rateLimited
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_150)
        let viewModel = await prepareLookupViewModel(
            harness: harness,
            shopmonkey: shopmonkey,
            now: now,
            selectedServiceID: "service_1"
        )
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        guard let operationID = viewModel.lastTicketMutationOperationID else {
            Issue.record("Missing queued operation id")
            return
        }
        let queued = await harness.queueStore.operation(id: operationID)
        #expect(queued?.status == .pending)
        #expect(queued?.retryCount == 1)
        #expect(queued?.lastErrorCode == DiagnosticCode.netRate429.rawValue)
        #expect(viewModel.ticketMutationState == .queued(diagnosticCode: DiagnosticCode.netRate429.rawValue))
    }

    @Test func incrementModeIsRejectedWhenRemoteQuantityUpdateIsUnavailable() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            servicesByOrderID: ["ticket_1": [.init(id: "service_1", name: "Brakes")]],
            servicesError: nil,
            createPartBehavior: { request in
                .init(id: "part_1", name: request.name)
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_300)
        let viewModel = await prepareLookupViewModel(
            harness: harness,
            shopmonkey: shopmonkey,
            now: now,
            selectedServiceID: "service_1"
        )
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .incrementQuantity)

        #expect(viewModel.ticketMutationState == .failed(diagnosticCode: nil))
        #expect(viewModel.ticketMutationMessage?.contains("Increment quantity is unavailable") == true)
        #expect(viewModel.lastTicketMutationOperationID == nil)
        #expect(await recorder.createPartCount() == 0)
        #expect(await harness.queueStore.allOperations().isEmpty)
    }
}
