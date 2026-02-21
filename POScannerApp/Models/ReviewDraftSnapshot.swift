//
//  ReviewDraftSnapshot.swift
//  POScannerApp
//

import Foundation

struct ReviewDraftSnapshot: Identifiable, Codable, Hashable {
    enum WorkflowState: String, Codable, Hashable {
        case scanning
        case ocrReview
        case parsing
        case reviewReady
        case reviewEdited
        case submitting
        case failed

        var statusLabel: String {
            switch self {
            case .scanning:
                return "Scanning"
            case .ocrReview:
                return "OCR Review"
            case .parsing:
                return "Parsing"
            case .reviewReady:
                return "Ready"
            case .reviewEdited:
                return "Edited"
            case .submitting:
                return "Submitting"
            case .failed:
                return "Needs Attention"
            }
        }
    }

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
        var headerVendorPhone: String? = nil
        var headerVendorEmail: String? = nil
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
            self.headerVendorPhone = invoice.header.vendorPhone
            self.headerVendorEmail = invoice.header.vendorEmail
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
                    vendorPhone: headerVendorPhone,
                    vendorEmail: headerVendorEmail,
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
        var vendorEmail: String? = nil
        var vendorNotes: String? = nil
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
        var workflowStateRawValue: String? = nil
        var workflowDetail: String? = nil
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
        switch workflowState {
        case .scanning, .ocrReview, .parsing, .submitting:
            if let detail = state.workflowDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                return detail
            }
            return workflowState.statusLabel
        case .reviewReady, .reviewEdited, .failed:
            break
        }

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

    var workflowState: WorkflowState {
        guard let raw = state.workflowStateRawValue,
              let parsed = WorkflowState(rawValue: raw) else {
            return .reviewReady
        }
        return parsed
    }

    var workflowProgressEstimate: Double {
        switch workflowState {
        case .scanning:
            return 0.20
        case .ocrReview:
            return 0.45
        case .parsing:
            return 0.66
        case .reviewReady:
            return 0.90
        case .reviewEdited:
            return 0.94
        case .submitting:
            return 0.98
        case .failed:
            return 0.55
        }
    }

    var isLiveIntakeSession: Bool {
        switch workflowState {
        case .scanning, .ocrReview, .parsing, .reviewReady, .reviewEdited, .submitting:
            return true
        case .failed:
            return false
        }
    }

    var canResumeInReview: Bool {
        switch workflowState {
        case .reviewReady, .reviewEdited, .failed, .submitting:
            return true
        case .scanning, .ocrReview, .parsing:
            return false
        }
    }

    var liveActivityRecencyWindow: TimeInterval {
        switch workflowState {
        case .scanning, .ocrReview, .parsing:
            return 20 * 60
        case .reviewReady, .reviewEdited:
            return 8 * 60
        case .submitting:
            return 25 * 60
        case .failed:
            return 0
        }
    }

    var liveActivityPayload: (status: String, detail: String, progress: Double)? {
        switch workflowState {
        case .scanning:
            return (
                status: "Capturing invoice",
                detail: "Step 1 of 4 • Running on-device OCR.",
                progress: max(0.20, workflowProgressEstimate)
            )
        case .ocrReview:
            return (
                status: "Reviewing OCR",
                detail: "Step 2 of 4 • Confirm text and barcode hints.",
                progress: max(0.45, workflowProgressEstimate)
            )
        case .parsing:
            return (
                status: "Parsing line items",
                detail: "Step 2 of 4 • Classifying parts, tires, and fees.",
                progress: max(0.64, workflowProgressEstimate)
            )
        case .reviewReady:
            return (
                status: "Draft ready",
                detail: "Step 3 of 4 • Verify lines before submit.",
                progress: max(0.90, workflowProgressEstimate)
            )
        case .reviewEdited:
            return (
                status: "Draft updated",
                detail: "Step 3 of 4 • Ready for Shopmonkey submission.",
                progress: max(0.94, workflowProgressEstimate)
            )
        case .submitting:
            return (
                status: "Submitting to Shopmonkey",
                detail: "Step 4 of 4 • Posting purchase order now.",
                progress: max(0.96, workflowProgressEstimate)
            )
        case .failed:
            return nil
        }
    }

    var liveActivityStageToken: String {
        switch workflowState {
        case .scanning:
            return "capture"
        case .ocrReview:
            return "ocr"
        case .parsing:
            return "parse"
        case .reviewReady, .reviewEdited:
            return "draft"
        case .submitting:
            return "submit"
        case .failed:
            return "fail"
        }
    }
}
