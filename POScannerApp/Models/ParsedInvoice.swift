//
//  ParsedInvoice.swift
//  POScannerApp
//

import Foundation

struct POHeaderFields: Hashable, Equatable {
    var vendorName: String = ""
    var vendorPhone: String? = nil
    var vendorEmail: String? = nil
    var vendorInvoiceNumber: String = ""
    var poReference: String = ""
    var workOrderId: String = ""
    var serviceId: String = ""
    var terms: String = ""
    var notes: String = ""
}

struct ParsedInvoiceConfidenceBreakdown: Hashable {
    static let vendorWeight = 0.3
    static let itemsWeight = 0.3
    static let totalWeight = 0.2
    static let invoiceWeight = 0.2

    var hasVendorName: Bool
    var hasItems: Bool
    var hasTotal: Bool
    var hasInvoiceNumber: Bool

    var score: Double {
        var total = 0.0
        if hasVendorName { total += Self.vendorWeight }
        if hasItems { total += Self.itemsWeight }
        if hasTotal { total += Self.totalWeight }
        if hasInvoiceNumber { total += Self.invoiceWeight }
        return total
    }
}

/// Pure parsing output from OCR/scanner text. No persistence, no networking, no side effects.
struct ParsedInvoice: Hashable {
    var vendorName: String?
    var poNumber: String?
    var invoiceNumber: String? = nil
    var totalCents: Int? = nil
    var items: [ParsedLineItem]
    var header: POHeaderFields = POHeaderFields()

    var confidenceBreakdown: ParsedInvoiceConfidenceBreakdown {
        ParsedInvoiceConfidenceBreakdown(
            hasVendorName: vendorName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasItems: !items.isEmpty,
            hasTotal: totalCents != nil,
            hasInvoiceNumber: invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        )
    }

    var confidenceScore: Double {
        confidenceBreakdown.score
    }
}

/// A single parsed line item produced by `POParser`.
struct ParsedLineItem: Hashable {
    var name: String
    var quantity: Int?
    var costCents: Int?
    var partNumber: String?
    var confidence: Double
    var kind: POItemKind = .unknown
    var kindConfidence: Double = 0
    var kindReasons: [String] = []
}
