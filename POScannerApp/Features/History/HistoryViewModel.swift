//
//  HistoryViewModel.swift
//  POScannerApp
//

import CoreData
import Combine
import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    struct HistoryRow: Identifiable, Hashable {
        let objectID: NSManagedObjectID
        let vendorName: String
        let poNumber: String?
        let date: Date
        let formattedDate: String
        let totalAmount: Double
        let formattedTotal: String
        let status: String
        let lastError: String?

        var id: NSManagedObjectID { objectID }

        fileprivate static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter
        }()

        fileprivate static let currencyFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            return formatter
        }()
    }

    @Published private(set) var orders: [HistoryRow] = []
    @Published private(set) var isLoading: Bool = false

    private let dataController: DataController

    init(dataController: DataController) {
        self.dataController = dataController
    }

    func loadHistory() {
        isLoading = true

        let container = dataController.container

        Task(priority: .userInitiated) {
            let backgroundContext = container.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

            let mapped: [HistoryRow] = await backgroundContext.perform {
                let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(key: "date", ascending: false)
                ]
                request.fetchLimit = 100

                let fetchedOrders = (try? backgroundContext.fetch(request)) ?? []
                return fetchedOrders.map { order in
                    let formattedTotal = HistoryRow.currencyFormatter.string(from: NSNumber(value: order.totalAmount))
                        ?? String(format: "%.2f", order.totalAmount)

                    return HistoryRow(
                        objectID: order.objectID,
                        vendorName: order.vendorName,
                        poNumber: order.poNumber,
                        date: order.date,
                        formattedDate: HistoryRow.dateFormatter.string(from: order.date),
                        totalAmount: order.totalAmount,
                        formattedTotal: formattedTotal,
                        status: order.status,
                        lastError: order.lastError
                    )
                }
            }

            orders = mapped
            isLoading = false
        }
    }

    func purchaseOrder(for row: HistoryRow) -> PurchaseOrder? {
        (try? dataController.viewContext.existingObject(with: row.objectID)) as? PurchaseOrder
    }
}
