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

        var lifecycleRank: Int {
            switch self {
            case .scanning:
                return 0
            case .ocrReview:
                return 1
            case .parsing:
                return 2
            case .reviewReady:
                return 3
            case .reviewEdited:
                return 4
            case .submitting:
                return 5
            case .failed:
                return 6
            }
        }

        func allowsTransition(to next: WorkflowState) -> Bool {
            if self == next {
                return true
            }

            if next == .failed {
                return true
            }

            if self == .failed {
                switch next {
                case .reviewReady, .reviewEdited, .submitting:
                    return true
                case .scanning, .ocrReview, .parsing, .failed:
                    return false
                }
            }

            if self == .reviewEdited && next == .reviewReady {
                return true
            }

            return next.lifecycleRank >= self.lifecycleRank
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
            return reviewLiveProgress(for: .reviewReady)
        case .reviewEdited:
            return reviewLiveProgress(for: .reviewEdited)
        case .submitting:
            return 0.92
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
            return 5 * 60
        case .reviewReady, .reviewEdited:
            return 5 * 60
        case .submitting:
            return 12 * 60
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
                status: reviewLiveStatus(for: .reviewReady),
                detail: "Step 3 of 4 • Verify lines before submit.",
                progress: max(0.78, workflowProgressEstimate)
            )
        case .reviewEdited:
            return (
                status: reviewLiveStatus(for: .reviewEdited),
                detail: "Step 3 of 4 • Ready for Shopmonkey submission.",
                progress: max(0.82, workflowProgressEstimate)
            )
        case .submitting:
            return (
                status: "Submitting to Shopmonkey",
                detail: "Step 4 of 4 • Posting purchase order now.",
                progress: max(0.92, workflowProgressEstimate)
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

    private var trimmedWorkflowDetail: String? {
        let trimmed = state.workflowDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var reviewReadinessScoreEstimate: Double {
        let vendor = state.vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelectedVendor = !(state.selectedVendorId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let vendorReady = (!vendor.isEmpty && hasSelectedVendor) ? 1.0 : 0.0

        let itemReadiness: Double
        if state.items.isEmpty {
            itemReadiness = 0
        } else {
            let unknownPenalty = Double(state.items.filter { $0.kind == .unknown }.count)
            let suggestedPenalty = Double(state.items.filter { $0.isKindConfidenceMedium }.count) * 0.5
            let penalty = (unknownPenalty + suggestedPenalty) / Double(state.items.count)
            itemReadiness = max(0, min(1, 1 - penalty))
        }

        let modeRawValue = state.modeUIRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasOrderContext = !state.orderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasServiceContext =
            !state.serviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(state.selectedTicketId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        let contextReady: Double
        switch modeRawValue {
        case "quickadd":
            contextReady = (hasOrderContext && hasServiceContext) ? 1.0 : 0.0
        case "attach", "restock":
            contextReady = 1.0
        default:
            contextReady = hasOrderContext || hasServiceContext ? 1.0 : 0.0
        }

        let score = (vendorReady + itemReadiness + contextReady) / 3.0
        guard score.isFinite else { return 0 }
        return max(0, min(1, score))
    }

    private func reviewLiveProgress(for workflowState: WorkflowState) -> Double {
        let readiness = reviewReadinessScoreEstimate

        switch workflowState {
        case .reviewReady:
            // Keep review-ready below edited/submitting while still reflecting readiness gains.
            return min(0.86, max(0.74, 0.72 + (readiness * 0.14)))
        case .reviewEdited:
            // Edited stage should visibly progress as vendor and line-item readiness improves.
            return min(0.90, max(0.78, 0.78 + (readiness * 0.12)))
        case .scanning:
            return 0.20
        case .ocrReview:
            return 0.45
        case .parsing:
            return 0.66
        case .submitting:
            return 0.92
        case .failed:
            return 0.55
        }
    }

    private func reviewLiveStatus(for workflowState: WorkflowState) -> String {
        guard let detail = trimmedWorkflowDetail?.lowercased() else {
            return workflowState == .reviewReady ? "Draft ready" : "Draft updated"
        }

        if detail.contains("vendor") {
            return "Vendor ready"
        }
        if detail.contains("suggestion") {
            return "Suggestions reviewed"
        }
        if detail.contains("line items reordered") || detail.contains("reordered") {
            return "Line order updated"
        }
        if detail.contains("line type") || detail.contains("classification") || detail.contains("reclassified") {
            return "Line types updated"
        }
        if detail.contains("removed") {
            return "Items removed"
        }

        return workflowState == .reviewReady ? "Draft ready" : "Draft updated"
    }
}
