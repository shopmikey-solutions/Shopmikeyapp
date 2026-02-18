//
//  ReviewDraftSnapshot.swift
//  POScannerApp
//

import Foundation

struct ReviewDraftSnapshot: Identifiable, Codable, Hashable {
    struct ParsedLineItemSnapshot: Codable, Hashable {
        var name: String
        var quantity: Int?
        var costCents: Int?
        var partNumber: String?
        var confidence: Double
        var kind: POItemKind
        var kindConfidence: Double
        var kindReasons: [String]

        init(item: ParsedLineItem) {
            self.name = item.name
            self.quantity = item.quantity
            self.costCents = item.costCents
            self.partNumber = item.partNumber
            self.confidence = item.confidence
            self.kind = item.kind
            self.kindConfidence = item.kindConfidence
            self.kindReasons = item.kindReasons
        }

        var parsedLineItem: ParsedLineItem {
            ParsedLineItem(
                name: name,
                quantity: quantity,
                costCents: costCents,
                partNumber: partNumber,
                confidence: confidence,
                kind: kind,
                kindConfidence: kindConfidence,
                kindReasons: kindReasons
            )
        }
    }

    struct ParsedInvoiceSnapshot: Codable, Hashable {
        var vendorName: String?
        var poNumber: String?
        var invoiceNumber: String?
        var totalCents: Int?
        var items: [ParsedLineItemSnapshot]
        var headerVendorName: String
        var headerVendorInvoiceNumber: String
        var headerPOReference: String
        var headerWorkOrderId: String
        var headerServiceId: String
        var headerTerms: String
        var headerNotes: String

        init(invoice: ParsedInvoice) {
            self.vendorName = invoice.vendorName
            self.poNumber = invoice.poNumber
            self.invoiceNumber = invoice.invoiceNumber
            self.totalCents = invoice.totalCents
            self.items = invoice.items.map(ParsedLineItemSnapshot.init(item:))
            self.headerVendorName = invoice.header.vendorName
            self.headerVendorInvoiceNumber = invoice.header.vendorInvoiceNumber
            self.headerPOReference = invoice.header.poReference
            self.headerWorkOrderId = invoice.header.workOrderId
            self.headerServiceId = invoice.header.serviceId
            self.headerTerms = invoice.header.terms
            self.headerNotes = invoice.header.notes
        }

        var parsedInvoice: ParsedInvoice {
            ParsedInvoice(
                vendorName: vendorName,
                poNumber: poNumber,
                invoiceNumber: invoiceNumber,
                totalCents: totalCents,
                items: items.map(\.parsedLineItem),
                header: POHeaderFields(
                    vendorName: headerVendorName,
                    vendorInvoiceNumber: headerVendorInvoiceNumber,
                    poReference: headerPOReference,
                    workOrderId: headerWorkOrderId,
                    serviceId: headerServiceId,
                    terms: headerTerms,
                    notes: headerNotes
                )
            )
        }
    }

    struct State: Codable, Hashable {
        var parsedInvoice: ParsedInvoiceSnapshot
        var vendorName: String
        var vendorPhone: String
        var vendorInvoiceNumber: String
        var poReference: String
        var notes: String
        var selectedVendorId: String?
        var orderId: String
        var serviceId: String
        var items: [POItem]
        var modeUIRawValue: String
        var ignoreTaxOverride: Bool
        var selectedPOId: String?
        var selectedTicketId: String?
    }

    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var state: State

    var displayVendorName: String {
        let candidate = state.vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            return candidate
        }

        if let parsed = state.parsedInvoice.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsed.isEmpty {
            return parsed
        }

        return "Draft Intake"
    }

    var displaySecondaryLine: String {
        let invoice = state.vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !invoice.isEmpty {
            return "Invoice \(invoice)"
        }

        let poReference = state.poReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !poReference.isEmpty {
            return "PO \(poReference)"
        }

        if let parsedInvoice = state.parsedInvoice.invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsedInvoice.isEmpty {
            return "Invoice \(parsedInvoice)"
        }

        if let parsedPO = state.parsedInvoice.poNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsedPO.isEmpty {
            return "PO \(parsedPO)"
        }

        return "\(state.items.count) line items"
    }
}
