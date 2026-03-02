//
//  StoreScalabilityTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct StoreScalabilityTests {
    private func temporaryURL(_ namespace: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("store_scalability_tests", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json", isDirectory: false)
    }

    @Test func inventoryStoreBuildsIndexesForConstantLookup() async {
        let fileURL = temporaryURL("inventory")
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = InventoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_773_000_000)
        let items = (0..<1_000).map { index in
            InventoryItem(
                id: "inv_\(index)",
                sku: "SKU-\(index)",
                partNumber: "PART-\(index)",
                description: "Item \(index)",
                quantityOnHand: Double(index % 5)
            )
        }
        await store.replaceAll(items, at: now)

        let debugCounts = await store.debugIndexCounts()
        #expect(debugCounts.sku == 1_000)
        #expect(debugCounts.partNumber == 1_000)

        let bySKU = await store.lookupItem(scannedCode: "SKU-777")
        let byPartNumber = await store.lookupItem(scannedCode: "part-998")

        #expect(bySKU?.id == "inv_777")
        #expect(byPartNumber?.id == "inv_998")
        #expect(await store.isStale(now: now.addingTimeInterval(601), threshold: 600))
    }

    @Test func ticketStoreEnforcesCapAndPaginationDeterministically() async {
        let fileURL = temporaryURL("tickets")
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        let tickets = (0..<350).map { index in
            TicketModel(
                id: "ticket_\(index)",
                displayNumber: "RO-\(index)",
                status: "Open",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_773_100_000 + index))
            )
        }

        _ = await store.saveOpenTicketsPage(
            page: 0,
            tickets: tickets,
            pageSize: 350,
            refreshedAt: Date(timeIntervalSince1970: 1_773_200_000)
        )

        #expect(await store.openTicketCount() == TicketStore.maxCacheTickets)
        #expect(await store.debugTicketIndexCount() == TicketStore.maxCacheTickets)
        #expect((await store.loadOpenTicketsPage(page: 0, pageSize: 50)).count == 50)
        #expect((await store.loadOpenTicketsPage(page: 5, pageSize: 50)).count == 50)
        #expect((await store.loadOpenTicketsPage(page: 6, pageSize: 50)).isEmpty)
    }

    @Test func purchaseOrderStoreEnforcesCapPagingAndFreshness() async {
        let fileURL = temporaryURL("purchase_orders")
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = PurchaseOrderStore(fileURL: fileURL)
        let summaries = (0..<350).map { index in
            PurchaseOrderSummary(
                id: "po_\(index)",
                vendorName: "Vendor \(index)",
                status: "Open",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_773_300_000 + index)),
                totalLineCount: index % 5
            )
        }

        _ = await store.saveOpenPurchaseOrdersPage(
            page: 0,
            orders: summaries,
            pageSize: 350,
            refreshedAt: Date(timeIntervalSince1970: 1_773_300_000)
        )

        #expect(await store.openPurchaseOrderCount() == PurchaseOrderStore.maxCachePurchaseOrders)
        #expect(await store.debugSummaryIndexCount() == PurchaseOrderStore.maxCachePurchaseOrders)
        #expect((await store.loadOpenPurchaseOrdersPage(page: 0, pageSize: 50)).count == 50)
        #expect((await store.loadOpenPurchaseOrdersPage(page: 5, pageSize: 50)).count == 50)
        #expect((await store.loadOpenPurchaseOrdersPage(page: 6, pageSize: 50)).isEmpty)
        #expect(await store.loadOpenPurchaseOrderSummary(id: "po_349") != nil)
        #expect(await store.isStale(
            now: Date(timeIntervalSince1970: 1_773_300_000 + 601),
            threshold: 600
        ))
    }
}
