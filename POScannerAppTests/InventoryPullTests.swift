//
//  InventoryPullTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

private struct InventorySyncShopmonkeyStub: ShopmonkeyServicing {
    var inventoryResult: Result<[InventoryItem], Error>

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        .init(id: "vendor_1", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        .init(id: "part_1", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }

    func fetchOrders() async throws -> [OrderSummary] { [] }

    func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }

    func fetchInventory() async throws -> [InventoryItem] {
        try inventoryResult.get()
    }

    func searchVendors(name: String) async throws -> [VendorSummary] { [] }

    func testConnection() async throws {}
}

@Suite(.serialized)
struct InventoryPullTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory_pull_tests", isDirectory: true)
            .appendingPathComponent("\(name)_\(UUID().uuidString).json", isDirectory: false)
    }

    private func makeSyncOperation(id: UUID = UUID()) -> SyncOperation {
        SyncOperation(
            id: id,
            type: .syncInventory,
            payloadFingerprint: "inventory.pull.test.\(id.uuidString.lowercased())",
            status: .pending,
            retryCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_772_164_800)
        )
    }

    @Test func inventoryStoreReplaceAllReplacesPreviousDataset() async {
        let fileURL = temporaryURL("inventory_store")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let firstItems = [
            InventoryItem(id: "a", sku: "A", partNumber: "A", description: "First", price: 10, quantityOnHand: 5),
            InventoryItem(id: "b", sku: "B", partNumber: "B", description: "Second", price: 20, quantityOnHand: 8)
        ]
        let replacementItems = [
            InventoryItem(id: "c", sku: "C", partNumber: "C", description: "Replacement", price: 30, quantityOnHand: 3)
        ]
        let syncDate = Date(timeIntervalSince1970: 1_772_200_000)

        let firstStore = InventoryStore(fileURL: fileURL)
        await firstStore.replaceAll(firstItems, at: syncDate)
        await firstStore.replaceAll(replacementItems, at: syncDate.addingTimeInterval(60))

        let secondStore = InventoryStore(fileURL: fileURL)
        let persisted = await secondStore.allItems()
        let persistedUpdatedAt = await secondStore.lastUpdatedAt()

        #expect(persisted.count == 1)
        #expect(persisted.first?.id == "c")
        #expect(persisted.first?.description == "Replacement")
        #expect(persistedUpdatedAt == syncDate.addingTimeInterval(60))
    }

    @Test func syncEngineProcessesSyncInventoryAndPersistsItems() async {
        let queueURL = temporaryURL("sync_queue_success")
        let inventoryURL = temporaryURL("inventory_store_success")
        defer {
            try? FileManager.default.removeItem(at: queueURL)
            try? FileManager.default.removeItem(at: inventoryURL)
            try? FileManager.default.removeItem(at: queueURL.deletingLastPathComponent())
        }

        let queueStore = SyncOperationQueueStore(fileURL: queueURL)
        let inventoryStore = InventoryStore(fileURL: inventoryURL)
        let now = Date(timeIntervalSince1970: 1_772_300_000)
        let stub = InventorySyncShopmonkeyStub(
            inventoryResult: .success([
                InventoryItem(id: "part_1", sku: "PAD-001", partNumber: "PAD-001", description: "Front Brake Pad Set", price: 99.95, quantityOnHand: 12)
            ])
        )

        let engine = AppEnvironment.makeSyncEngine(
            syncOperationQueue: queueStore,
            dateProvider: FixedDateProvider(date: now),
            shopmonkeyAPI: stub,
            inventoryStore: inventoryStore
        )

        let operation = makeSyncOperation()
        _ = await queueStore.enqueue(operation)
        await engine.runOnce()

        let remaining = await queueStore.allOperations()
        let storedItems = await inventoryStore.allItems()
        let lastUpdatedAt = await inventoryStore.lastUpdatedAt()

        #expect(remaining.isEmpty)
        #expect(storedItems.count == 1)
        #expect(storedItems.first?.id == "part_1")
        #expect(lastUpdatedAt == now)
    }

    @Test func syncInventoryTransientFailureKeepsOperationQueuedForRetry() async {
        let queueURL = temporaryURL("sync_queue_failure")
        let inventoryURL = temporaryURL("inventory_store_failure")
        defer {
            try? FileManager.default.removeItem(at: queueURL)
            try? FileManager.default.removeItem(at: inventoryURL)
            try? FileManager.default.removeItem(at: queueURL.deletingLastPathComponent())
        }

        let queueStore = SyncOperationQueueStore(fileURL: queueURL)
        let inventoryStore = InventoryStore(fileURL: inventoryURL)
        let now = Date(timeIntervalSince1970: 1_772_400_000)
        let stub = InventorySyncShopmonkeyStub(
            inventoryResult: .failure(APIError.network(URLError(.timedOut)))
        )

        let engine = AppEnvironment.makeSyncEngine(
            syncOperationQueue: queueStore,
            dateProvider: FixedDateProvider(date: now),
            shopmonkeyAPI: stub,
            inventoryStore: inventoryStore
        )

        let operation = makeSyncOperation()
        _ = await queueStore.enqueue(operation)
        await engine.runOnce()

        let persisted = await queueStore.operation(id: operation.id)
        #expect(persisted?.status == .pending)
        #expect(persisted?.retryCount == 1)
        if let nextAttempt = persisted?.nextAttemptAt {
            #expect(nextAttempt >= now.addingTimeInterval(27))
            #expect(nextAttempt <= now.addingTimeInterval(33))
        } else {
            #expect(Bool(false))
        }
        #expect(persisted?.lastErrorCode == DiagnosticCode.netTimeoutRequest.rawValue)
    }
}

private struct FixedDateProvider: DateProviding {
    let date: Date
    var now: Date { date }
}
