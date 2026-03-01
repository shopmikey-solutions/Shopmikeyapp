//
//  ScanSuggestionTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite struct ScanSuggestionTests {
    @Test
    func poMatchWithRemainingQuantityHasHighestPriority() {
        let suggestion = ScanSuggestionEngine.suggest(
            scannedCode: "sku-1",
            inventoryMatch: InventoryItem(id: "inv-1", sku: "SKU-1", partNumber: "PN-1", description: "Brake Pad", quantityOnHand: 0.5),
            activeTicket: TicketModel(id: "ticket-1"),
            openPurchaseOrders: [
                PurchaseOrderDetail(
                    id: "po-1",
                    lineItems: [
                        PurchaseOrderLineItem(
                            id: "line-1",
                            sku: "SKU-1",
                            description: "Brake Pad",
                            quantityOrdered: 5,
                            quantityReceived: 1
                        )
                    ]
                )
            ]
        )

        #expect(suggestion == .receivePO(poId: "po-1", lineItemId: "line-1"))
    }

    @Test
    func fullyReceivedPOLineIsIgnored() {
        let suggestion = ScanSuggestionEngine.suggest(
            scannedCode: "sku-1",
            inventoryMatch: nil,
            activeTicket: nil,
            openPurchaseOrders: [
                PurchaseOrderDetail(
                    id: "po-closed-line",
                    lineItems: [
                        PurchaseOrderLineItem(
                            id: "line-closed",
                            sku: "SKU-1",
                            description: "Brake Pad",
                            quantityOrdered: 2,
                            quantityReceived: 2
                        )
                    ]
                )
            ]
        )

        #expect(suggestion == .none)
    }

    @Test
    func activeTicketSuggestionWhenInventoryMatchesAndNoReceivablePO() {
        let suggestion = ScanSuggestionEngine.suggest(
            scannedCode: "sku-2",
            inventoryMatch: InventoryItem(id: "inv-2", sku: "SKU-2", partNumber: "PN-2", description: "Oil Filter", quantityOnHand: 10),
            activeTicket: TicketModel(id: "ticket-2"),
            openPurchaseOrders: []
        )

        #expect(suggestion == .addToTicket(ticketId: "ticket-2"))
    }

    @Test
    func lowStockSuggestionWhenNoPOAndNoActiveTicket() {
        let suggestion = ScanSuggestionEngine.suggest(
            scannedCode: "sku-3",
            inventoryMatch: InventoryItem(id: "inv-3", sku: "SKU-3", partNumber: "PN-3", description: "Rotor", quantityOnHand: 1),
            activeTicket: nil,
            openPurchaseOrders: []
        )

        #expect(suggestion == .addToPODraft)
    }

    @Test
    func noMatchFallbackWhenNoSignalsPresent() {
        let suggestion = ScanSuggestionEngine.suggest(
            scannedCode: "unknown",
            inventoryMatch: nil,
            activeTicket: nil,
            openPurchaseOrders: []
        )

        #expect(suggestion == .none)
    }

    @Test
    func poPriorityBeatsTicketAndRestock() {
        let suggestion = ScanSuggestionEngine.suggest(
            scannedCode: "abc-123",
            inventoryMatch: InventoryItem(id: "inv-4", sku: "ABC-123", partNumber: "", description: "Spark Plug", quantityOnHand: 0),
            activeTicket: TicketModel(id: "ticket-priority"),
            openPurchaseOrders: [
                PurchaseOrderDetail(
                    id: "po-priority",
                    lineItems: [
                        PurchaseOrderLineItem(
                            id: "line-priority",
                            sku: "abc-123",
                            description: "Spark Plug",
                            quantityOrdered: 3,
                            quantityReceived: 0
                        )
                    ]
                )
            ]
        )

        #expect(suggestion == .receivePO(poId: "po-priority", lineItemId: "line-priority"))
    }
}
