//
//  OperationsViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import ShopmikeyCoreModels
import ShopmikeyCoreSync

@MainActor
final class OperationsViewModel: ObservableObject {
    private let inventoryStore: any InventoryStoring
    private let purchaseOrderStore: any PurchaseOrderStoring
    private let ticketStore: any TicketStoring
    private let syncOperationQueue: SyncOperationQueueStore
    private let lowStockThreshold: Double
    private let maxLowStockRows: Int

    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var lowStockItems: [InventoryItem] = []
    @Published private(set) var openPurchaseOrderCount: Int = 0
    @Published private(set) var openTicketCount: Int = 0
    @Published private(set) var pendingSyncCount: Int = 0
    @Published private(set) var failedSyncCount: Int = 0
    @Published private(set) var inProgressSyncCount: Int = 0

    init(
        inventoryStore: any InventoryStoring,
        purchaseOrderStore: any PurchaseOrderStoring,
        ticketStore: any TicketStoring,
        syncOperationQueue: SyncOperationQueueStore,
        lowStockThreshold: Double = 1,
        maxLowStockRows: Int = 8
    ) {
        self.inventoryStore = inventoryStore
        self.purchaseOrderStore = purchaseOrderStore
        self.ticketStore = ticketStore
        self.syncOperationQueue = syncOperationQueue
        self.lowStockThreshold = lowStockThreshold
        self.maxLowStockRows = max(1, maxLowStockRows)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        async let inventoryItemsTask = inventoryStore.allItems()
        async let openPurchaseOrdersTask = purchaseOrderStore.loadOpenPurchaseOrders()
        async let openTicketsTask = ticketStore.loadOpenTickets()
        async let operationsTask = syncOperationQueue.allOperations()

        let inventoryItems = await inventoryItemsTask
        let openPurchaseOrders = await openPurchaseOrdersTask
        let openTickets = await openTicketsTask
        let operations = await operationsTask

        lowStockItems = inventoryItems
            .filter { item in
                item.normalizedQuantityOnHand <= lowStockThreshold
            }
            .sorted { lhs, rhs in
                if lhs.normalizedQuantityOnHand == rhs.normalizedQuantityOnHand {
                    return lhs.displayPartNumber.localizedCaseInsensitiveCompare(rhs.displayPartNumber) == .orderedAscending
                }
                return lhs.normalizedQuantityOnHand < rhs.normalizedQuantityOnHand
            }
            .prefix(maxLowStockRows)
            .map { $0 }

        openPurchaseOrderCount = openPurchaseOrders.count
        openTicketCount = openTickets.count
        pendingSyncCount = operations.lazy.filter { $0.status == .pending }.count
        failedSyncCount = operations.lazy.filter { $0.status == .failed }.count
        inProgressSyncCount = operations.lazy.filter { $0.status == .inProgress }.count
        lastRefreshedAt = Date()
    }
}
