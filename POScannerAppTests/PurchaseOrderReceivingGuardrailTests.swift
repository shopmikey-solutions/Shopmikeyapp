//
//  PurchaseOrderReceivingGuardrailTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite
struct PurchaseOrderReceivingGuardrailTests {
    @Test
    func purchaseOrderLineItemComputedQuantitiesAreDeterministic() {
        let lineItem = PurchaseOrderLineItem(
            id: "line_1",
            description: "Brake Pad",
            quantityOrdered: 5,
            quantityReceived: 2
        )

        #expect(lineItem.orderedQty == Decimal(5))
        #expect(lineItem.receivedQty == Decimal(2))
        #expect(lineItem.remainingQty == Decimal(3))
        #expect(lineItem.isFullyReceived == false)
    }

    @Test
    func purchaseOrderLineItemComputedQuantitiesClampToZero() {
        let lineItem = PurchaseOrderLineItem(
            id: "line_2",
            description: "Oil Filter",
            quantityOrdered: 2,
            quantityReceived: 7
        )

        #expect(lineItem.receivedQty == Decimal(7))
        #expect(lineItem.remainingQty == .zero)
        #expect(lineItem.isFullyReceived == true)
    }

    @Test
    func receivePayloadFingerprintCarriesTaggedReceiveKeyDescription() {
        let payload = PurchaseOrderLineItemReceivePayload(
            purchaseOrderID: "po_1",
            lineItemID: "line_1",
            quantityReceived: 1,
            priorReceivedQuantity: 0,
            barcode: "BP-100",
            sku: "SKU-100",
            partNumber: "BP-100",
            description: "Brake Pad"
        )

        let roundTrip = PurchaseOrderLineItemReceivePayload.from(payloadFingerprint: payload.payloadFingerprint)
        let decodedDescription = roundTrip?.description ?? ""

        #expect(decodedDescription.hasPrefix(PurchaseOrderLineItemReceivePayload.receiveKeyPrefix))
        #expect(decodedDescription.contains("|brake pad"))
    }
}
