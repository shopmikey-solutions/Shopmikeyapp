//
//  ScanViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import CoreGraphics
import CoreData
import ImageIO
import UIKit

@MainActor
final class ScanViewModel: ObservableObject {
    enum ProcessingStage: String {
        case extractingText = "Extracting text"
        case preparingReview = "Preparing OCR review"
        case parsing = "Classifying line items"
        case finalizing = "Preparing review"

        var progressEstimate: Double {
            switch self {
            case .extractingText:
                return 0.28
            case .preparingReview:
                return 0.45
            case .parsing:
                return 0.64
            case .finalizing:
                return 0.9
            }
        }

        var detail: String {
            switch self {
            case .extractingText:
                return "Running OCR on your document."
            case .preparingReview:
                return "Building a highlighted review draft."
            case .parsing:
                return "Applying AI + rules to structure fields."
            case .finalizing:
                return "Building a review-ready draft."
            }
        }
    }

    let environment: AppEnvironment

    struct ParsedInvoiceRoute: Hashable {
        let id: UUID = UUID()
        let invoice: ParsedInvoice
    }

    struct OCRReviewDraft: Identifiable {
        let id: UUID = UUID()
        let image: UIImage
        let extraction: OCRService.DocumentExtraction
        let ignoreTaxAndTotals: Bool
    }

    struct RecentSummary: Hashable {
        let vendor: String
        let total: String
        let date: String
    }

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var parsedInvoiceRoute: ParsedInvoiceRoute?
    @Published var ocrReviewDraft: OCRReviewDraft?
    @Published private(set) var processingStartedAt: Date?
    @Published private(set) var processingStage: ProcessingStage?
    @Published var todayCount: Int = 0
    @Published var todayTotal: Decimal = 0
    @Published var pendingCount: Int = 0
    @Published var submittedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var mostRecentSummary: RecentSummary?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func handleScannedImage(
        _ image: UIImage,
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        ignoreTaxAndTotals: Bool
    ) {
        errorMessage = nil
        Task {
            await processScannedImage(
                image,
                cgImage: cgImage,
                orientation: orientation,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
        }
    }

    func handleScannedImage(_ cgImage: CGImage, orientation: CGImagePropertyOrientation, ignoreTaxAndTotals: Bool) {
        let previewImage = UIImage(cgImage: cgImage, scale: 1, orientation: orientation.uiImageOrientation)
        handleScannedImage(
            previewImage,
            cgImage: cgImage,
            orientation: orientation,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
    }

    func cancelOCRReview() {
        ocrReviewDraft = nil
    }

    func continueFromOCRReview(editedText: String, includeDetectedBarcodes: Bool) {
        guard let draft = ocrReviewDraft else { return }
        ocrReviewDraft = nil

        let barcodes = includeDetectedBarcodes ? draft.extraction.barcodes : []
        Task {
            await parseReviewedText(
                editedText,
                barcodeHints: barcodes,
                ignoreTaxAndTotals: draft.ignoreTaxAndTotals
            )
        }
    }

    private func parseReviewedText(
        _ reviewedText: String,
        barcodeHints: [OCRService.DetectedBarcode],
        ignoreTaxAndTotals: Bool
    ) async {
        let baseText = reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else {
            errorMessage = "No text available to parse."
            return
        }

        errorMessage = nil
        isProcessing = true
        processingStartedAt = Date()
        processingStage = .parsing

        let handoff = environment.parseHandoffService.build(
            reviewedText: baseText,
            barcodeHints: barcodeHints
        )

        let rulesInvoice = environment.poParser.parse(
            from: handoff.rulesInputText,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
        let aiEligible = shouldRunOnDeviceAI(rulesInvoice: rulesInvoice, handoff: handoff)

        let ai: ParsedInvoice?
        if aiEligible {
            ai = await environment.foundationModelService.parseInvoiceIfAvailable(
                from: handoff.modelInputText,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
        } else {
            ai = nil
        }

        let invoice = mergedParsedInvoice(aiInvoice: ai, rulesInvoice: rulesInvoice)
        processingStage = .finalizing
        logScanDiagnostics(
            handoff: handoff,
            invoice: invoice,
            rulesInvoice: rulesInvoice,
            aiEligible: aiEligible,
            usedAI: ai != nil,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: invoice)

        isProcessing = false
        processingStage = nil
        processingStartedAt = nil
    }

    var uiTestReviewFixtureEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-review-fixture")
    }

    func openUITestReviewFixture() {
        guard uiTestReviewFixtureEnabled else { return }
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: Self.uiTestReviewInvoice)
    }

    private func processScannedImage(
        _ image: UIImage,
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        ignoreTaxAndTotals: Bool
    ) async {
        isProcessing = true
        errorMessage = nil
        processingStartedAt = Date()
        processingStage = .extractingText

        do {
            let extraction = try await environment.ocrService.extractDocument(from: cgImage, orientation: orientation)
            processingStage = .preparingReview
            ocrReviewDraft = OCRReviewDraft(
                image: image,
                extraction: extraction,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
        } catch {
            errorMessage = "Failed to process scan."
        }

        isProcessing = false
        processingStage = nil
        processingStartedAt = nil
    }

    var processingProgressEstimate: Double {
        processingStage?.progressEstimate ?? 0
    }

    var processingStatusText: String {
        processingStage?.rawValue ?? "Processing scan"
    }

    var processingDetailText: String {
        processingStage?.detail ?? "Preparing scan result."
    }

    private func logScanDiagnostics(
        handoff: ParseHandoffPayload,
        invoice: ParsedInvoice,
        rulesInvoice: ParsedInvoice,
        aiEligible: Bool,
        usedAI: Bool,
        ignoreTaxAndTotals: Bool
    ) {
        #if DEBUG
        let source: String = {
            if usedAI { return "ai+rules" }
            if aiEligible { return "rules-only(ai-failed)" }
            return "rules-only(prequalified)"
        }()
        let confidence = String(format: "%.2f", invoice.confidenceScore)
        let rulesConfidence = String(format: "%.2f", rulesInvoice.confidenceScore)
        let unknownRate = String(format: "%.2f", unknownKindRate(in: invoice) * 100)
        print(
            "[ScanDiag] source=\(source) localOnly=true ignoreTax=\(ignoreTaxAndTotals) confidence=\(confidence) rulesConfidence=\(rulesConfidence) items=\(invoice.items.count) unknownRate=\(unknownRate)%"
        )
        print(
            "[ScanDiag][Handoff] rawLines=\(handoff.metrics.rawLineCount) dedupedLines=\(handoff.metrics.deduplicatedLineCount) rulesLines=\(handoff.metrics.ruleLineCount) modelLines=\(handoff.metrics.modelLineCount) rawChars=\(handoff.metrics.rawCharacterCount) rulesChars=\(handoff.metrics.rulesCharacterCount) modelChars=\(handoff.metrics.modelCharacterCount) rulesTrimmed=\(handoff.metrics.rulesTrimmed) modelTrimmed=\(handoff.metrics.modelTrimmed) barcodes=\(handoff.metrics.barcodeCount)"
        )
        print(
            "[ScanDiag] header vendor='\(invoice.vendorName ?? "")' invoice='\(invoice.invoiceNumber ?? "")' po='\(invoice.poNumber ?? "")' totalCents=\(invoice.totalCents ?? 0)"
        )

        for (index, item) in invoice.items.enumerated() {
            let kindConfidence = String(format: "%.2f", item.kindConfidence)
            let reasonText = item.kindReasons.joined(separator: " | ")
            print(
                "[ScanDiag][Item \(index + 1)] kind=\(item.kind.rawValue) kindConfidence=\(kindConfidence) qty=\(item.quantity ?? 1) costCents=\(item.costCents ?? 0) part='\(item.partNumber ?? "")' name='\(item.name)' reasons='\(reasonText)'"
            )
        }
        #endif
    }

    private func shouldRunOnDeviceAI(rulesInvoice: ParsedInvoice, handoff: ParseHandoffPayload) -> Bool {
        guard environment.foundationModelService.isOnDeviceModelAvailable else {
            return false
        }
        guard handoff.hasModelInput else {
            return false
        }
        guard !rulesInvoice.items.isEmpty else {
            return true
        }

        let rulesUnknownRate = unknownKindRate(in: rulesInvoice)
        let rulesIsStrong = rulesInvoice.confidenceScore >= 0.80 && rulesUnknownRate <= 0.12
        if rulesIsStrong && rulesInvoice.items.count >= 3 {
            return false
        }

        return true
    }

    private func mergedParsedInvoice(aiInvoice: ParsedInvoice?, rulesInvoice: ParsedInvoice) -> ParsedInvoice {
        guard var ai = aiInvoice else {
            return rulesInvoice
        }

        if ai.items.isEmpty {
            ai.items = rulesInvoice.items
        } else if !rulesInvoice.items.isEmpty {
            let aiUnknownRate = unknownKindRate(in: ai)
            let rulesUnknownRate = unknownKindRate(in: rulesInvoice)
            let aiItemFloor = max(1, Int((Double(rulesInvoice.items.count) * 0.55).rounded(.up)))

            if ai.items.count < aiItemFloor || aiUnknownRate > rulesUnknownRate + 0.25 {
                ai.items = rulesInvoice.items
            }
        }

        ai.vendorName = preferred(ai.vendorName, fallback: rulesInvoice.vendorName)
        ai.invoiceNumber = preferred(ai.invoiceNumber, fallback: rulesInvoice.invoiceNumber)
        ai.poNumber = preferred(ai.poNumber, fallback: rulesInvoice.poNumber)

        if ai.totalCents == nil || ai.totalCents == 0 {
            ai.totalCents = rulesInvoice.totalCents ?? computedTotalCents(from: ai.items)
        }

        ai.header.vendorName = preferred(nonEmpty(ai.header.vendorName), fallback: nonEmpty(rulesInvoice.header.vendorName)) ?? ""
        ai.header.vendorInvoiceNumber = preferred(nonEmpty(ai.header.vendorInvoiceNumber), fallback: nonEmpty(rulesInvoice.header.vendorInvoiceNumber)) ?? ""
        ai.header.poReference = preferred(nonEmpty(ai.header.poReference), fallback: nonEmpty(rulesInvoice.header.poReference)) ?? ""
        ai.header.workOrderId = preferred(nonEmpty(ai.header.workOrderId), fallback: nonEmpty(rulesInvoice.header.workOrderId)) ?? ""
        ai.header.serviceId = preferred(nonEmpty(ai.header.serviceId), fallback: nonEmpty(rulesInvoice.header.serviceId)) ?? ""
        ai.header.terms = preferred(nonEmpty(ai.header.terms), fallback: nonEmpty(rulesInvoice.header.terms)) ?? ""
        ai.header.notes = preferred(nonEmpty(ai.header.notes), fallback: nonEmpty(rulesInvoice.header.notes)) ?? ""

        return ai
    }

    private func unknownKindRate(in invoice: ParsedInvoice) -> Double {
        guard !invoice.items.isEmpty else { return 1.0 }
        let unknownCount = invoice.items.filter { $0.kind == .unknown }.count
        return Double(unknownCount) / Double(invoice.items.count)
    }

    private func computedTotalCents(from items: [ParsedLineItem]) -> Int? {
        let total = items.reduce(0) { partial, item in
            partial + ((item.costCents ?? 0) * max(1, item.quantity ?? 1))
        }
        return total > 0 ? total : nil
    }

    private func preferred(_ primary: String?, fallback: String?) -> String? {
        nonEmpty(primary) ?? nonEmpty(fallback)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func loadTodayMetrics() {
        let container = environment.dataController.container

        Task(priority: .userInitiated) {
            let context = container.newBackgroundContext()
            let metrics = await context.perform { () -> (
                count: Int,
                pending: Int,
                submitted: Int,
                failed: Int,
                total: Decimal,
                recent: RecentSummary?
            ) in
                let startOfDay = Calendar.current.startOfDay(for: Date())

                let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
                request.predicate = NSPredicate(format: "date >= %@", startOfDay as NSDate)
                request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

                let results = (try? context.fetch(request)) ?? []
                let count = results.count
                let pending = results.filter { $0.status.lowercased() == "submitting" }.count
                let submitted = results.filter { $0.status.lowercased() == "submitted" }.count
                let failed = results.filter { $0.status.lowercased() == "failed" }.count
                let total = results.reduce(Decimal.zero) { partial, order in
                    partial + Decimal(order.totalAmount)
                }

                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .short

                let currencyFormatter = NumberFormatter()
                currencyFormatter.numberStyle = .currency
                currencyFormatter.minimumFractionDigits = 2
                currencyFormatter.maximumFractionDigits = 2

                let recent = results.first.map { order in
                    let vendor = order.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Unknown Vendor"
                        : order.vendorName
                    let totalText = currencyFormatter.string(from: NSNumber(value: order.totalAmount)) ?? "$0.00"
                    let dateText = dateFormatter.string(from: order.date)
                    return RecentSummary(vendor: vendor, total: totalText, date: dateText)
                }

                return (count, pending, submitted, failed, total, recent)
            }

            todayCount = metrics.count
            todayTotal = metrics.total
            pendingCount = metrics.pending
            submittedCount = metrics.submitted
            failedCount = metrics.failed
            mostRecentSummary = metrics.recent
        }
    }

    var todayTotalFormatted: String {
        let number = NSDecimalNumber(decimal: todayTotal)
        return Self.currencyFormatter.string(from: number) ?? "0.00"
    }

    var todayAverageFormatted: String {
        guard todayCount > 0 else { return "$0.00" }
        let total = NSDecimalNumber(decimal: todayTotal)
        let count = NSDecimalNumber(value: todayCount)
        let average = total.dividing(by: count)
        return Self.currencyFormatter.string(from: average) ?? "$0.00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let uiTestReviewInvoice: ParsedInvoice = {
        ParsedInvoice(
            vendorName: "METRO AUTO PARTS SUPPLY",
            poNumber: "PO-99012",
            invoiceNumber: "MAP-45821",
            totalCents: 164_212,
            items: [
                ParsedLineItem(
                    name: "Front Brake Pad Set - Ceramic",
                    quantity: 6,
                    costCents: 6_800,
                    partNumber: "ACD-41-993",
                    confidence: 0.95,
                    kind: .part,
                    kindConfidence: 0.90,
                    kindReasons: ["ui test fixture"]
                ),
                ParsedLineItem(
                    name: "225/60/16 Primacy Michelin",
                    quantity: 4,
                    costCents: 18_000,
                    partNumber: "MICH-123",
                    confidence: 0.95,
                    kind: .tire,
                    kindConfidence: 0.90,
                    kindReasons: ["ui test fixture"]
                ),
                ParsedLineItem(
                    name: "Shipping",
                    quantity: 1,
                    costCents: 4_500,
                    partNumber: nil,
                    confidence: 0.90,
                    kind: .fee,
                    kindConfidence: 0.85,
                    kindReasons: ["ui test fixture"]
                )
            ],
            header: POHeaderFields(
                vendorName: "METRO AUTO PARTS SUPPLY",
                vendorInvoiceNumber: "MAP-45821",
                poReference: "PO-99012",
                workOrderId: "",
                serviceId: "",
                terms: "",
                notes: ""
            )
        )
    }()
}

private extension CGImagePropertyOrientation {
    var uiImageOrientation: UIImage.Orientation {
        switch self {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .upMirrored:
            return .upMirrored
        case .downMirrored:
            return .downMirrored
        case .leftMirrored:
            return .leftMirrored
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }
}
