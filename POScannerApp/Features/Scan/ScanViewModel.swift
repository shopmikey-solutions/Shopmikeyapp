//
//  ScanViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import CoreGraphics
import CoreData
import ImageIO

@MainActor
final class ScanViewModel: ObservableObject {
    let environment: AppEnvironment

    struct ParsedInvoiceRoute: Hashable {
        let id: UUID = UUID()
        let invoice: ParsedInvoice
    }

    struct RecentSummary: Hashable {
        let vendor: String
        let total: String
        let date: String
    }

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var parsedInvoiceRoute: ParsedInvoiceRoute?
    @Published var todayCount: Int = 0
    @Published var todayTotal: Decimal = 0
    @Published var pendingCount: Int = 0
    @Published var submittedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var mostRecentSummary: RecentSummary?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func handleScannedImage(_ cgImage: CGImage, orientation: CGImagePropertyOrientation, ignoreTaxAndTotals: Bool) {
        errorMessage = nil
        Task {
            await processScannedImage(cgImage, orientation: orientation, ignoreTaxAndTotals: ignoreTaxAndTotals)
        }
    }

    var uiTestReviewFixtureEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-review-fixture")
    }

    func openUITestReviewFixture() {
        guard uiTestReviewFixtureEnabled else { return }
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: Self.uiTestReviewInvoice)
    }

    private func processScannedImage(_ cgImage: CGImage, orientation: CGImagePropertyOrientation, ignoreTaxAndTotals: Bool) async {
        isProcessing = true
        errorMessage = nil

        do {
            let extracted = try await environment.ocrService.extractText(from: cgImage, orientation: orientation)
            let ai = await environment.foundationModelService.parseInvoiceIfAvailable(from: extracted, ignoreTaxAndTotals: ignoreTaxAndTotals)
            let invoice = ai ?? environment.poParser.parse(from: extracted, ignoreTaxAndTotals: ignoreTaxAndTotals)
            logScanDiagnostics(
                extractedText: extracted,
                invoice: invoice,
                usedAI: ai != nil,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
            parsedInvoiceRoute = ParsedInvoiceRoute(invoice: invoice)
        } catch {
            errorMessage = "Failed to process scan."
        }

        isProcessing = false
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
