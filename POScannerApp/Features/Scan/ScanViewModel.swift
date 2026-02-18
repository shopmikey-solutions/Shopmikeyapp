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

        let parseInput: String
        if barcodeHints.isEmpty {
            parseInput = baseText
        } else {
            let barcodeBlock = barcodeHints
                .map { "[BARCODE \($0.symbology)] \($0.payload)" }
                .joined(separator: "\n")
            parseInput = "\(baseText)\n\nDetected barcodes:\n\(barcodeBlock)"
        }

        let ai = await environment.foundationModelService.parseInvoiceIfAvailable(
            from: parseInput,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
        let invoice = ai ?? environment.poParser.parse(from: parseInput, ignoreTaxAndTotals: ignoreTaxAndTotals)
        processingStage = .finalizing
        logScanDiagnostics(
            extractedText: parseInput,
            invoice: invoice,
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
        extractedText: String,
        invoice: ParsedInvoice,
        usedAI: Bool,
        ignoreTaxAndTotals: Bool
    ) {
        #if DEBUG
        let lineCount = extractedText.split(whereSeparator: \.isNewline).count
        let source = usedAI ? "ai+rules" : "rules-only"
        let confidence = String(format: "%.2f", invoice.confidenceScore)
        print(
            "[ScanDiag] source=\(source) ignoreTax=\(ignoreTaxAndTotals) chars=\(extractedText.count) lines=\(lineCount) confidence=\(confidence) items=\(invoice.items.count)"
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
