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

/// Pure parsing output from OCR/scanner text. No persistence, no networking, no side effects.
struct ParsedInvoice: Hashable {
    var vendorName: String?
    var poNumber: String?
    var invoiceNumber: String? = nil
    var totalCents: Int? = nil
    var items: [ParsedLineItem]
    var header: POHeaderFields = POHeaderFields()

    var confidenceScore: Double {
        var score = 0.0

        if vendorName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            score += 0.3
        }
        if !items.isEmpty {
            score += 0.3
        }
        if totalCents != nil {
            score += 0.2
        }
        if invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            score += 0.2
        }

        return score
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
