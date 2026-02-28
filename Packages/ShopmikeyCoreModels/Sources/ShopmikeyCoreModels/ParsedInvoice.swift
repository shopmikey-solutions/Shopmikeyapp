//
//  ParsedInvoice.swift
//  POScannerApp
//

import Foundation

public struct POHeaderFields: Hashable, Equatable, Sendable {
    public var vendorName: String = ""
    public var vendorPhone: String? = nil
    public var vendorEmail: String? = nil
    public var vendorInvoiceNumber: String = ""
    public var poReference: String = ""
    public var workOrderId: String = ""
    public var serviceId: String = ""
    public var terms: String = ""
    public var notes: String = ""

    public init(
        vendorName: String = "",
        vendorPhone: String? = nil,
        vendorEmail: String? = nil,
        vendorInvoiceNumber: String = "",
        poReference: String = "",
        workOrderId: String = "",
        serviceId: String = "",
        terms: String = "",
        notes: String = ""
    ) {
        self.vendorName = vendorName
        self.vendorPhone = vendorPhone
        self.vendorEmail = vendorEmail
        self.vendorInvoiceNumber = vendorInvoiceNumber
        self.poReference = poReference
        self.workOrderId = workOrderId
        self.serviceId = serviceId
        self.terms = terms
        self.notes = notes
    }
}

public struct ParsedInvoiceConfidenceBreakdown: Hashable, Sendable {
    public static let vendorWeight = 0.3
    public static let itemsWeight = 0.3
    public static let totalWeight = 0.2
    public static let invoiceWeight = 0.2

    public var hasVendorName: Bool
    public var hasItems: Bool
    public var hasTotal: Bool
    public var hasInvoiceNumber: Bool

    public init(
        hasVendorName: Bool,
        hasItems: Bool,
        hasTotal: Bool,
        hasInvoiceNumber: Bool
    ) {
        self.hasVendorName = hasVendorName
        self.hasItems = hasItems
        self.hasTotal = hasTotal
        self.hasInvoiceNumber = hasInvoiceNumber
    }

    public var score: Double {
        var total = 0.0
        if hasVendorName { total += Self.vendorWeight }
        if hasItems { total += Self.itemsWeight }
        if hasTotal { total += Self.totalWeight }
        if hasInvoiceNumber { total += Self.invoiceWeight }
        return total
    }
}

/// Pure parsing output from OCR/scanner text. No persistence, no networking, no side effects.
public struct ParsedInvoice: Hashable, Sendable {
    public var vendorName: String?
    public var poNumber: String?
    public var invoiceNumber: String? = nil
    public var totalCents: Int? = nil
    public var items: [ParsedLineItem]
    public var header: POHeaderFields = POHeaderFields()

    public init(
        vendorName: String? = nil,
        poNumber: String? = nil,
        invoiceNumber: String? = nil,
        totalCents: Int? = nil,
        items: [ParsedLineItem],
        header: POHeaderFields = POHeaderFields()
    ) {
        self.vendorName = vendorName
        self.poNumber = poNumber
        self.invoiceNumber = invoiceNumber
        self.totalCents = totalCents
        self.items = items
        self.header = header
    }

    public var confidenceBreakdown: ParsedInvoiceConfidenceBreakdown {
        ParsedInvoiceConfidenceBreakdown(
            hasVendorName: vendorName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasItems: !items.isEmpty,
            hasTotal: totalCents != nil,
            hasInvoiceNumber: invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        )
    }

    public var confidenceScore: Double {
        confidenceBreakdown.score
    }
}

/// A single parsed line item produced by `POParser`.
public struct ParsedLineItem: Hashable, Sendable {
    public var name: String
    public var quantity: Int?
    public var costCents: Int?
    public var partNumber: String?
    public var confidence: Double
    public var kind: POItemKind = .unknown
    public var kindConfidence: Double = 0
    public var kindReasons: [String] = []

    public init(
        name: String,
        quantity: Int? = nil,
        costCents: Int? = nil,
        partNumber: String? = nil,
        confidence: Double,
        kind: POItemKind = .unknown,
        kindConfidence: Double = 0,
        kindReasons: [String] = []
    ) {
        self.name = name
        self.quantity = quantity
        self.costCents = costCents
        self.partNumber = partNumber
        self.confidence = confidence
        self.kind = kind
        self.kindConfidence = kindConfidence
        self.kindReasons = kindReasons
    }
}
