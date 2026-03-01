//
//  PurchaseOrderLineItem.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct PurchaseOrderLineItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: String?
    public var sku: String?
    public var partNumber: String?
    public var description: String
    public var quantityOrdered: Decimal
    public var quantityReceived: Decimal?
    public var unitCost: Decimal?
    public var extendedCost: Decimal?

    public init(
        id: String,
        kind: String? = nil,
        sku: String? = nil,
        partNumber: String? = nil,
        description: String,
        quantityOrdered: Decimal,
        quantityReceived: Decimal? = nil,
        unitCost: Decimal? = nil,
        extendedCost: Decimal? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sku = sku
        self.partNumber = partNumber
        self.description = description
        self.quantityOrdered = quantityOrdered
        self.quantityReceived = quantityReceived
        self.unitCost = unitCost
        self.extendedCost = extendedCost
    }

    public var orderedQty: Decimal {
        max(0, quantityOrdered)
    }

    public var receivedQty: Decimal {
        max(0, quantityReceived ?? 0)
    }

    public var remainingQty: Decimal {
        max(0, orderedQty - receivedQty)
    }

    public var isFullyReceived: Bool {
        remainingQty <= .zero
    }
}
