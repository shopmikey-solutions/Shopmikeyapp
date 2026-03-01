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

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ticket_add_line_item_tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            queueFileURL = root.appendingPathComponent("queue.json", isDirectory: false)
            ticketFileURL = root.appendingPathComponent("tickets.json", isDirectory: false)
            queueStore = SyncOperationQueueStore(fileURL: queueFileURL)
            ticketStore = TicketStore(fileURL: ticketFileURL)
            inventoryStore = InventoryStore()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
        }
    }

    private actor RequestRecorder {
        struct Request: Equatable {
            var ticketID: String
            var sku: String?
            var partNumber: String?
            var description: String
            var quantity: Decimal
            var unitPrice: Decimal?
        }

        private(set) var requests: [Request] = []

        func append(_ request: Request) {
            requests.append(request)
        }

        func last() -> Request? {
            requests.last
        }
    }

    private struct ShopmonkeyStub: ShopmonkeyServicing {
        let recorder: RequestRecorder
        let addBehavior: @Sendable () async throws -> TicketLineItem

        func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
            .init(id: "vendor_1", name: request.name)
        }

        func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
            .init(id: "part_1", name: request.name)
        }

        func fetchOrders() async throws -> [OrderSummary] { [] }
        func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
        func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
        func searchVendors(name: String) async throws -> [VendorSummary] { [] }
        func fetchOpenTickets() async throws -> [TicketModel] { [] }
        func fetchTicket(id: String) async throws -> TicketModel { TicketModel(id: id, lineItems: []) }
        func fetchInventory() async throws -> [InventoryItem] { [] }
        func testConnection() async throws {}

        func addPartLineItem(
            toTicketId ticketId: String,
            sku: String?,
            partNumber: String?,
            description: String,
            quantity: Decimal,
            unitPrice: Decimal?
        ) async throws -> TicketLineItem {
            await recorder.append(
                .init(
                    ticketID: ticketId,
                    sku: sku,
                    partNumber: partNumber,
                    description: description,
                    quantity: quantity,
                    unitPrice: unitPrice
                )
            )
            return try await addBehavior()
        }
    }

    private func prepareLookupViewModel(
        harness: StoreHarness,
        shopmonkey: any ShopmonkeyServicing,
        now: Date
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

        await harness.ticketStore.save(ticket: TicketModel(
            id: "ticket_1",
            number: "RO-1001",
            status: "Open",
            lineItems: []
        ))
        await harness.ticketStore.setActiveTicketID("ticket_1")

        let engine = AppEnvironment.makeSyncEngine(
            syncOperationQueue: harness.queueStore,
            dateProvider: FixedDateProvider(date: now),
            shopmonkeyAPI: shopmonkey,
            ticketStore: harness.ticketStore,
            inventoryStore: harness.inventoryStore
        )

        let viewModel = InventoryLookupViewModel(
            inventoryStore: harness.inventoryStore,
            ticketStore: harness.ticketStore,
            syncOperationQueue: harness.queueStore,
            syncEngine: engine,
            dateProvider: FixedDateProvider(date: now)
        )
        await viewModel.lookup(scannedCode: "PAD-001")
        return viewModel
    }

    @Test func addToTicketSuccessCallsEndpointAndRemovesQueuedOperation() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            addBehavior: {
                TicketLineItem(
                    id: "line_1",
                    kind: "part",
                    sku: "PAD-001",
                    partNumber: "PAD-001",
                    description: "Front Brake Pad Set",
                    quantity: 1,
                    unitPrice: 99.95,
                    extendedPrice: 99.95,
                    vendorId: "vendor_1"
                )
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_000)
        let viewModel = await prepareLookupViewModel(harness: harness, shopmonkey: shopmonkey, now: now)
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        let request = await recorder.last()
        #expect(request?.ticketID == "ticket_1")
        #expect(request?.sku == "PAD-001")
        #expect(request?.partNumber == "PAD-001")
        #expect(request?.description == "Front Brake Pad Set")
        #expect(NSDecimalNumber(decimal: request?.quantity ?? 0).doubleValue == 1)
        #expect(NSDecimalNumber(decimal: request?.unitPrice ?? 0).doubleValue == 99.95)
        #expect(viewModel.ticketMutationState == .succeeded)

        let operationID = try? #require(viewModel.lastTicketMutationOperationID)
        if let operationID {
            #expect(await harness.queueStore.operation(id: operationID) == nil)
        }

        let ticket = await harness.ticketStore.loadTicket(id: "ticket_1")
        #expect(ticket?.lineItems.count == 1)
        #expect(ticket?.lineItems.first?.id == "line_1")
    }

    @Test func transientFailureLeavesOperationQueuedForRetry() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            addBehavior: {
                throw APIError.rateLimited
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_100)
        let viewModel = await prepareLookupViewModel(harness: harness, shopmonkey: shopmonkey, now: now)
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

    @Test func permanentFailureMarksOperationFailedWithDiagnostic() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        let recorder = RequestRecorder()
        let shopmonkey = ShopmonkeyStub(
            recorder: recorder,
            addBehavior: {
                throw APIError.unauthorized
            }
        )

        let now = Date(timeIntervalSince1970: 1_772_500_200)
        let viewModel = await prepareLookupViewModel(harness: harness, shopmonkey: shopmonkey, now: now)
        await viewModel.addMatchedItemToTicket(ticketID: "ticket_1", mergeMode: .addNewLine)

        guard let operationID = viewModel.lastTicketMutationOperationID else {
            Issue.record("Missing failed operation id")
            return
        }

        let failed = await harness.queueStore.operation(id: operationID)
        #expect(failed?.status == .failed)
        #expect(failed?.retryCount == 0)
        #expect(failed?.lastErrorCode == DiagnosticCode.authUnauthorized401.rawValue)
        #expect(viewModel.ticketMutationState == .failed(diagnosticCode: DiagnosticCode.authUnauthorized401.rawValue))
    }
}
