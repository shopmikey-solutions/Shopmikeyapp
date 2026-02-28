//
//  POSubmissionPayload.swift
//  POScannerApp
//

import Foundation

/// Strongly-typed contract for submitting a reviewed purchase order to Shopmonkey.
public struct POSubmissionPayload: Hashable, Sendable {
    public var vendorId: String? = nil
    public var vendorName: String
    public var vendorPhone: String?
    public var notes: String? = nil
    public var invoiceNumber: String? = nil
    public var poReference: String? = nil
    public var poNumber: String?
    public var purchaseOrderId: String? = nil
    public var orderId: String?
    public var serviceId: String?
    public var items: [POItem]
    public var allowExistingPOLinking: Bool = false

    public init(
        vendorId: String? = nil,
        vendorName: String,
        vendorPhone: String? = nil,
        notes: String? = nil,
        invoiceNumber: String? = nil,
        poReference: String? = nil,
        poNumber: String? = nil,
        purchaseOrderId: String? = nil,
        orderId: String? = nil,
        serviceId: String? = nil,
        items: [POItem],
        allowExistingPOLinking: Bool = false
    ) {
        self.vendorId = vendorId
        self.vendorName = vendorName
        self.vendorPhone = vendorPhone
        self.notes = notes
        self.invoiceNumber = invoiceNumber
        self.poReference = poReference
        self.poNumber = poNumber
        self.purchaseOrderId = purchaseOrderId
        self.orderId = orderId
        self.serviceId = serviceId
        self.items = items
        self.allowExistingPOLinking = allowExistingPOLinking
    }

    public var isValid: Bool {
        validationMessage == nil
    }

    public var validationMessage: String? {
        let vendor = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if vendor.isEmpty {
            return "Vendor name is required."
        }

        if items.isEmpty {
            return "At least one item is required."
        }

        for item in items {
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Item name is required."
            }
            if item.quantity < 1 {
                return "Item quantity must be at least 1."
            }
            if !item.cost.isFinite {
                return "Item cost must be a valid number."
            }
            if item.costCents < 0 {
                return "Item cost must be at least 0."
            }
        }

        return nil
    }
}
