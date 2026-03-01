//
//  InventoryLookupTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct InventoryLookupTests {
    @Test @MainActor
    func lookupMatchesSkuExactly() async {
        let store = InventoryLookupStoreStub(items: [
            InventoryItem(id: "1", sku: "SKU-100", partNumber: "PART-100", description: "Brake Pad", quantityOnHand: 8)
        ])
        let viewModel = InventoryLookupViewModel(inventoryStore: store)

        await viewModel.lookup(scannedCode: "SKU-100")

        guard case .matchFound(let item) = viewModel.state else {
            Issue.record("Expected sku exact match.")
            return
        }
        #expect(item.id == "1")
    }

    @Test @MainActor
    func lookupMatchesPartNumberExactly() async {
        let store = InventoryLookupStoreStub(items: [
            InventoryItem(id: "2", sku: "SKU-200", partNumber: "PART-200", description: "Oil Filter", quantityOnHand: 3)
        ])
        let viewModel = InventoryLookupViewModel(inventoryStore: store)

        await viewModel.lookup(scannedCode: "PART-200")

        guard case .matchFound(let item) = viewModel.state else {
            Issue.record("Expected part number exact match.")
            return
        }
        #expect(item.id == "2")
    }

    @Test @MainActor
    func lookupReturnsNoMatchWhenInventoryDoesNotContainCode() async {
        let store = InventoryLookupStoreStub(items: [
            InventoryItem(id: "3", sku: "SKU-300", partNumber: "PART-300", description: "Wiper Blade", quantityOnHand: 6)
        ])
        let viewModel = InventoryLookupViewModel(inventoryStore: store)

        await viewModel.lookup(scannedCode: "UNKNOWN")

        #expect(viewModel.state == .noMatch)
    }

    @Test @MainActor
    func lookupNormalizesCaseAndWhitespace() async {
        let store = InventoryLookupStoreStub(items: [
            InventoryItem(id: "4", sku: "sku-400", partNumber: "part-400", description: "Headlight Bulb", quantityOnHand: 2)
        ])
        let viewModel = InventoryLookupViewModel(inventoryStore: store)

        await viewModel.lookup(scannedCode: "  SKU-400  ")

        guard case .matchFound(let item) = viewModel.state else {
            Issue.record("Expected normalized match.")
            return
        }
        #expect(item.id == "4")
    }
}

private actor InventoryLookupStoreStub: InventoryStoring {
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
