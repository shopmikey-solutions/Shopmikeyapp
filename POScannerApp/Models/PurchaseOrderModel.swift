//
//  PurchaseOrderModel.swift
//  POScannerApp
//

import Foundation

struct PurchaseOrderModel: Identifiable, Hashable, Codable {
    var id: String
    var vendorId: String?
    var vendorName: String?
    var poNumber: String?
    var items: [POItem]
    var totalAmount: Double
    var status: String
}

