//
//  TicketLineItem.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct TicketLineItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: String?
    public var sku: String?
    public var partNumber: String?
    public var description: String
    public var quantity: Decimal
    public var unitPrice: Decimal?
    public var extendedPrice: Decimal?
    public var vendorId: String?

    public init(
        id: String,
        kind: String? = nil,
        sku: String? = nil,
        partNumber: String? = nil,
        description: String,
        quantity: Decimal = 0,
        unitPrice: Decimal? = nil,
        extendedPrice: Decimal? = nil,
        vendorId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sku = sku
        self.partNumber = partNumber
        self.description = description
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.extendedPrice = extendedPrice
        self.vendorId = vendorId
    }
}
