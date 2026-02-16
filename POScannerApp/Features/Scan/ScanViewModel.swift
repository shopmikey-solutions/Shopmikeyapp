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

    private func processScannedImage(_ cgImage: CGImage, orientation: CGImagePropertyOrientation, ignoreTaxAndTotals: Bool) async {
        isProcessing = true
        errorMessage = nil

        do {
            let extracted = try await environment.ocrService.extractText(from: cgImage, orientation: orientation)
            let ai = await environment.foundationModelService.parseInvoiceIfAvailable(from: extracted, ignoreTaxAndTotals: ignoreTaxAndTotals)
            let invoice = ai ?? environment.poParser.parse(from: extracted, ignoreTaxAndTotals: ignoreTaxAndTotals)
            parsedInvoiceRoute = ParsedInvoiceRoute(invoice: invoice)
        } catch {
            errorMessage = "Failed to process scan."
        }

        isProcessing = false
    }

    func loadTodayMetrics() {
        let container = environment.dataController.container

        Task(priority: .userInitiated) {
            let context = container.newBackgroundContext()
            let metrics = await context.perform { () -> (count: Int, pending: Int, total: Decimal, recent: RecentSummary?) in
                let startOfDay = Calendar.current.startOfDay(for: Date())

                let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
                request.predicate = NSPredicate(format: "date >= %@", startOfDay as NSDate)
                request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

                let results = (try? context.fetch(request)) ?? []
                let count = results.count
                let pending = results.filter { $0.status.lowercased() == "submitting" }.count
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

                return (count, pending, total, recent)
            }

            todayCount = metrics.count
            todayTotal = metrics.total
            pendingCount = metrics.pending
            mostRecentSummary = metrics.recent
        }
    }

    var todayTotalFormatted: String {
        let number = NSDecimalNumber(decimal: todayTotal)
        return Self.currencyFormatter.string(from: number) ?? "0.00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
