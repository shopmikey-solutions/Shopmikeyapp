//
//  OperationsViewModelTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct OperationsViewModelTests {
    @Test @MainActor
    func refreshComputesCountsAndLowStockRowsDeterministically() async {
        let inventoryStore = OperationsInventoryStoreStub(items: [
            InventoryItem(id: "A", sku: "SKU-A", partNumber: "PN-A", description: "Low item", quantityOnHand: 0),
            InventoryItem(id: "B", sku: "SKU-B", partNumber: "PN-B", description: "Boundary item", quantityOnHand: 1),
            InventoryItem(id: "C", sku: "SKU-C", partNumber: "PN-C", description: "Healthy item", quantityOnHand: 7)
        ])
        let purchaseOrderStore = OperationsPurchaseOrderStoreStub(openPurchaseOrders: [
            PurchaseOrderSummary(id: "po-1", vendorName: "Vendor A", status: "open", createdAt: Date(), updatedAt: Date(), totalLineCount: 2),
            PurchaseOrderSummary(id: "po-2", vendorName: "Vendor B", status: "open", createdAt: Date(), updatedAt: Date(), totalLineCount: 1)
        ])
        let ticketStore = OperationsTicketStoreStub(openTickets: [
            TicketModel(id: "ticket-1", number: "101"),
            TicketModel(id: "ticket-2", number: "102")
        ])
        let queueFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("operations_vm_queue_\(UUID().uuidString).json")
        let queue = SyncOperationQueueStore(fileURL: queueFileURL)

        defer {
            try? FileManager.default.removeItem(at: queueFileURL)
        }

        _ = await queue.enqueue(
            SyncOperation(
                id: UUID(),
                type: .syncInventory,
                payloadFingerprint: "ops.pending",
                status: .pending,
                retryCount: 0,
                createdAt: Date()
            )
        )
        _ = await queue.enqueue(
            SyncOperation(
                id: UUID(),
                type: .addTicketLineItem,
                payloadFingerprint: "ops.failed",
                status: .failed,
                retryCount: 1,
                createdAt: Date()
            )
        )
        _ = await queue.enqueue(
            SyncOperation(
                id: UUID(),
                type: .receivePurchaseOrderLineItem,
                payloadFingerprint: "ops.inProgress",
                status: .inProgress,
                retryCount: 0,
                createdAt: Date()
            )
        )

        let viewModel = OperationsViewModel(
            inventoryStore: inventoryStore,
            purchaseOrderStore: purchaseOrderStore,
            ticketStore: ticketStore,
            syncOperationQueue: queue,
            lowStockThreshold: 1,
            maxLowStockRows: 5
        )

        await viewModel.refresh()

        #expect(viewModel.openPurchaseOrderCount == 2)
        #expect(viewModel.openTicketCount == 2)
        #expect(viewModel.pendingSyncCount == 1)
        #expect(viewModel.failedSyncCount == 1)
        #expect(viewModel.inProgressSyncCount == 1)
        #expect(viewModel.lowStockItems.map(\.id) == ["A", "B"])
        #expect(viewModel.lastRefreshedAt != nil)
    }

    @Test @MainActor
    func lowStockRowsRespectConfiguredTopN() async {
        let inventoryStore = OperationsInventoryStoreStub(items: [
            InventoryItem(id: "A", sku: "1", partNumber: "A", description: "A", quantityOnHand: 0),
            InventoryItem(id: "B", sku: "2", partNumber: "B", description: "B", quantityOnHand: 0),
            InventoryItem(id: "C", sku: "3", partNumber: "C", description: "C", quantityOnHand: 1)
        ])
        let purchaseOrderStore = OperationsPurchaseOrderStoreStub(openPurchaseOrders: [])
        let ticketStore = OperationsTicketStoreStub(openTickets: [])
        let queueFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("operations_vm_queue_topn_\(UUID().uuidString).json")
        let queue = SyncOperationQueueStore(fileURL: queueFileURL)

        defer {
            try? FileManager.default.removeItem(at: queueFileURL)
        }

        let viewModel = OperationsViewModel(
            inventoryStore: inventoryStore,
            purchaseOrderStore: purchaseOrderStore,
            ticketStore: ticketStore,
            syncOperationQueue: queue,
            lowStockThreshold: 1,
            maxLowStockRows: 2
        )

        await viewModel.refresh()

        #expect(viewModel.lowStockItems.count == 2)
        #expect(viewModel.lowStockItems.map(\.id) == ["A", "B"])
    }
}

private actor OperationsInventoryStoreStub: InventoryStoring {
    private let items: [InventoryItem]

    init(items: [InventoryItem]) {
        self.items = items
    }

    func allItems() async -> [InventoryItem] {
        items
    }

    func replaceAll(_ items: [InventoryItem], at date: Date) async {
        _ = items
        _ = date
    }

    func incrementOnHand(
        sku: String?,
        partNumber: String?,
        description: String?,
        by quantity: Decimal,
        at date: Date
    ) async -> Bool {
        _ = sku
        _ = partNumber
        _ = description
        _ = quantity
        _ = date
        return false
    }

    func lastUpdatedAt() async -> Date? {
        nil
    }
}

private actor OperationsPurchaseOrderStoreStub: PurchaseOrderStoring {
    private let openPurchaseOrders: [PurchaseOrderSummary]

    init(openPurchaseOrders: [PurchaseOrderSummary]) {
        self.openPurchaseOrders = openPurchaseOrders
    }

    func saveOpenPurchaseOrders(_ orders: [PurchaseOrderSummary]) async {
        _ = orders
    }

    func loadOpenPurchaseOrders() async -> [PurchaseOrderSummary] {
        openPurchaseOrders
    }

    func loadOpenPurchaseOrderDetails() async -> [PurchaseOrderDetail] {
        []
    }

    func savePurchaseOrderDetail(_ detail: PurchaseOrderDetail) async {
        _ = detail
    }

    func applyReceiveResult(_ detail: PurchaseOrderDetail, at date: Date) async {
        _ = detail
        _ = date
    }

    func loadPurchaseOrderDetail(id: String) async -> PurchaseOrderDetail? {
        _ = id
        return nil
    }

    func clear() async {}
}

private actor OperationsTicketStoreStub: TicketStoring {
    private let openTickets: [TicketModel]

    init(openTickets: [TicketModel]) {
        self.openTickets = openTickets
    }

    func save(ticket: TicketModel) async {
        _ = ticket
    }

    func save(tickets: [TicketModel]) async {
        _ = tickets
    }

    func loadTicket(id: String) async -> TicketModel? {
        _ = id
        return nil
    }

    func loadOpenTickets() async -> [TicketModel] {
        openTickets
    }

    func activeTicketID() async -> String? {
        openTickets.first?.id
    }

    func loadActiveTicket() async -> TicketModel? {
        openTickets.first
    }

    func setActiveTicketID(_ id: String?) async {
        _ = id
    }

    func hasMatchingLineItem(ticketID: String, sku: String?, partNumber: String?, description: String?) async -> Bool {
        _ = ticketID
        _ = sku
        _ = partNumber
        _ = description
        return false
    }

    func findMatchingLineItem(ticketID: String, sku: String?, partNumber: String?, description: String?) async -> TicketLineItem? {
        _ = ticketID
        _ = sku
        _ = partNumber
        _ = description
        return nil
    }

    func applyAddedLineItem(
        _ lineItem: TicketLineItem,
        toTicketID ticketID: String,
        mergeMode: TicketLineMergeMode,
        updatedAt: Date
    ) async -> TicketModel? {
        _ = lineItem
        _ = ticketID
        _ = mergeMode
        _ = updatedAt
        return nil
    }

    func clear() async {}
}
