//
//  PurchaseOrderDetail.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct PurchaseOrderDetail: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var vendorName: String?
    public var status: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var lineItems: [PurchaseOrderLineItem]

    public init(
        id: String,
        vendorName: String? = nil,
        status: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        lineItems: [PurchaseOrderLineItem] = []
    ) {
        self.id = id
        self.vendorName = vendorName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lineItems = lineItems
    }
}
