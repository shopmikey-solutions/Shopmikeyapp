//
//  PurchaseOrderSummary.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct PurchaseOrderSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var vendorName: String?
    public var status: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var totalLineCount: Int?

    public init(
        id: String,
        vendorName: String? = nil,
        status: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        totalLineCount: Int? = nil
    ) {
        self.id = id
        self.vendorName = vendorName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.totalLineCount = totalLineCount
    }
}
