//
//  POSubmissionPayload.swift
//  POScannerApp
//

import Foundation

/// Strongly-typed contract for submitting a reviewed purchase order to Shopmonkey.
struct POSubmissionPayload: Hashable {
    var vendorId: String? = nil
    var vendorName: String
    var vendorPhone: String?
    var poNumber: String?
    var orderId: String?
    var serviceId: String?
    var items: [POItem]

    var isValid: Bool {
        validationMessage == nil
    }

    var validationMessage: String? {
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
