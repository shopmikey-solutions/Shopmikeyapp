//
//  PurchaseOrderStoreTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct PurchaseOrderStoreTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase_order_store_tests", isDirectory: true)
            .appendingPathComponent("\(name)_\(UUID().uuidString).json", isDirectory: false)
    }

    @Test func saveAndLoadRoundTripsAcrossInstances() async {
        let fileURL = temporaryURL("roundtrip")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = PurchaseOrderStore(fileURL: fileURL)
        let summaries = [
            PurchaseOrderSummary(
                id: "po_1",
                vendorName: "Alpha Supply",
                status: "Draft",
                createdAt: Date(timeIntervalSince1970: 1_772_600_000),
                updatedAt: Date(timeIntervalSince1970: 1_772_600_500),
                totalLineCount: 2
            ),
            PurchaseOrderSummary(
                id: "po_2",
                vendorName: "Bravo Supply",
                status: "Ordered",
                createdAt: Date(timeIntervalSince1970: 1_772_500_000),
                updatedAt: Date(timeIntervalSince1970: 1_772_500_500),
                totalLineCount: 1
            )
        ]
        let detail = PurchaseOrderDetail(
            id: "po_1",
            vendorName: "Alpha Supply",
            status: "Draft",
            lineItems: [
                PurchaseOrderLineItem(
                    id: "line_1",
                    kind: "part",
                    sku: "SKU-100",
                    partNumber: "PN-100",
                    description: "Brake Pad",
                    quantityOrdered: 2,
                    quantityReceived: 1,
                    unitCost: 12.99,
                    extendedCost: 25.98
                )
            ]
        )

        await store.saveOpenPurchaseOrders(summaries)
        await store.savePurchaseOrderDetail(detail)

        let reopened = PurchaseOrderStore(fileURL: fileURL)
        let loadedSummaries = await reopened.loadOpenPurchaseOrders()
        let loadedDetail = await reopened.loadPurchaseOrderDetail(id: "po_1")

        #expect(loadedSummaries.count == 2)
        #expect(loadedSummaries.first?.id == "po_1")
        #expect(loadedSummaries.first?.totalLineCount == 2)
        #expect(loadedDetail?.id == "po_1")
        #expect(loadedDetail?.lineItems.count == 1)
        #expect(loadedDetail?.lineItems.first?.description == "Brake Pad")
    }

    @Test func clearRemovesCachedSummariesAndDetails() async {
        let fileURL = temporaryURL("clear")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = PurchaseOrderStore(fileURL: fileURL)
        await store.saveOpenPurchaseOrders([
            PurchaseOrderSummary(id: "po_1", vendorName: "Alpha", status: "Draft", totalLineCount: 1)
        ])
        await store.savePurchaseOrderDetail(
            PurchaseOrderDetail(id: "po_1", vendorName: "Alpha", status: "Draft")
        )

        await store.clear()

        #expect(await store.loadOpenPurchaseOrders().isEmpty)
        #expect(await store.loadPurchaseOrderDetail(id: "po_1") == nil)
    }

    @Test func invalidJSONRecoversSafely() async throws {
        let fileURL = temporaryURL("corruption")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"broken\":".utf8).write(to: fileURL, options: .atomic)

        let store = PurchaseOrderStore(fileURL: fileURL)
        #expect(await store.loadOpenPurchaseOrders().isEmpty)
        #expect(await store.loadPurchaseOrderDetail(id: "po_1") == nil)

        await store.saveOpenPurchaseOrders([
            PurchaseOrderSummary(id: "po_2", vendorName: "Recovered", status: "Draft", totalLineCount: 0)
        ])
        #expect(await store.loadOpenPurchaseOrders().count == 1)
    }
}
