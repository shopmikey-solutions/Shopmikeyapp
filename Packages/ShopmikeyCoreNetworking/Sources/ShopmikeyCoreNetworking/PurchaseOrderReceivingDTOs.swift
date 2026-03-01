//
//  PurchaseOrderReceivingDTOs.swift
//  ShopmikeyCoreNetworking
//

import Foundation

struct ReceivePurchaseOrderLineItemRequest: Encodable, Sendable {
    let lineItemId: String
    let quantityReceived: Decimal?

    enum CodingKeys: String, CodingKey {
        case lineItemIDSnake = "line_item_id"
        case lineItemIDCamel = "lineItemId"
        case id
        case quantityReceivedSnake = "quantity_received"
        case quantityReceivedCamel = "quantityReceived"
        case receivedQuantitySnake = "received_quantity"
        case receivedQuantityCamel = "receivedQuantity"
        case quantity
        case qty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lineItemId, forKey: .lineItemIDSnake)
        try container.encode(lineItemId, forKey: .lineItemIDCamel)
        try container.encode(lineItemId, forKey: .id)

        guard let quantityReceived else {
            return
        }

        try container.encode(quantityReceived, forKey: .quantityReceivedSnake)
        try container.encode(quantityReceived, forKey: .quantityReceivedCamel)
        try container.encode(quantityReceived, forKey: .receivedQuantitySnake)
        try container.encode(quantityReceived, forKey: .receivedQuantityCamel)
        try container.encode(quantityReceived, forKey: .quantity)
        try container.encode(quantityReceived, forKey: .qty)
    }
}

struct ReceivePurchaseOrderRequest: Encodable, Sendable {
    let lineItems: [ReceivePurchaseOrderLineItemRequest]

    enum CodingKeys: String, CodingKey {
        case lineItemsSnake = "line_items"
        case lineItemsCamel = "lineItems"
        case items
        case receivedItemsSnake = "received_items"
        case receivedItemsCamel = "receivedItems"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lineItems, forKey: .lineItemsSnake)
        try container.encode(lineItems, forKey: .lineItemsCamel)
        try container.encode(lineItems, forKey: .items)
        try container.encode(lineItems, forKey: .receivedItemsSnake)
        try container.encode(lineItems, forKey: .receivedItemsCamel)
    }
}
