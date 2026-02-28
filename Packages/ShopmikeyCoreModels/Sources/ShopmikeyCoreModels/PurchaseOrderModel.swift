//
//  PurchaseOrderModel.swift
//  POScannerApp
//

import Foundation

public struct PurchaseOrderModel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var vendorId: String?
    public var vendorName: String?
    public var poNumber: String?
    public var items: [POItem]
    public var totalAmount: Double
    public var status: String

    public init(
        id: String,
        vendorId: String? = nil,
        vendorName: String? = nil,
        poNumber: String? = nil,
        items: [POItem],
        totalAmount: Double,
        status: String
    ) {
        self.id = id
        self.vendorId = vendorId
        self.vendorName = vendorName
        self.poNumber = poNumber
        self.items = items
        self.totalAmount = totalAmount
        self.status = status
    }
}
