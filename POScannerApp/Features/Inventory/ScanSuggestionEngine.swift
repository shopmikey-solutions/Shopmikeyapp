//
//  ScanSuggestionEngine.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

enum ScanSuggestionEngine {
    static let lowStockThreshold: Double = 1

    static func suggest(
        scannedCode: String?,
        inventoryMatch: InventoryItem?,
        activeTicket: TicketModel?,
        openPurchaseOrders: [PurchaseOrderDetail]
    ) -> ScanSuggestion {
        guard let normalizedScannedCode = normalized(scannedCode) else {
            return .none
        }

        if let matchedLine = firstReceivablePOMatch(
            for: normalizedScannedCode,
            openPurchaseOrders: openPurchaseOrders
        ) {
            return .receivePO(poId: matchedLine.poID, lineItemId: matchedLine.lineItemID)
        }

        if let activeTicketID = normalized(activeTicket?.id),
           inventoryMatch != nil {
            return .addToTicket(ticketId: activeTicketID)
        }

        if let inventoryMatch,
           inventoryMatch.normalizedQuantityOnHand <= lowStockThreshold {
            return .addToPODraft
        }

        return .none
    }

    private static func firstReceivablePOMatch(
        for normalizedScannedCode: String,
        openPurchaseOrders: [PurchaseOrderDetail]
    ) -> (poID: String, lineItemID: String)? {
        for order in openPurchaseOrders {
            guard let poID = normalized(order.id) else { continue }

            if let skuMatch = order.lineItems.first(where: { line in
                line.remainingQty > .zero && normalized(line.sku) == normalizedScannedCode
            }),
               let lineID = normalized(skuMatch.id) {
                return (poID: poID, lineItemID: lineID)
            }

            if let partMatch = order.lineItems.first(where: { line in
                line.remainingQty > .zero && normalized(line.partNumber) == normalizedScannedCode
            }),
               let lineID = normalized(partMatch.id) {
                return (poID: poID, lineItemID: lineID)
            }

            if let descriptionMatch = order.lineItems.first(where: { line in
                guard line.remainingQty > .zero else { return false }
                guard normalized(line.sku) == nil, normalized(line.partNumber) == nil else {
                    return false
                }
                return normalized(line.description) == normalizedScannedCode
            }),
               let lineID = normalized(descriptionMatch.id) {
                return (poID: poID, lineItemID: lineID)
            }
        }

        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
