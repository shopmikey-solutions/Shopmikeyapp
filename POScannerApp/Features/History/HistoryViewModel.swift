//
//  HistoryViewModel.swift
//  POScannerApp
//

import CoreData
import Combine
import Foundation
import os

@MainActor
final class HistoryViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.History")

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
    @Published private(set) var inProgressDrafts: [ReviewDraftSnapshot] = []
    @Published private(set) var isLoading: Bool = false

    private let dataController: DataController
    private let reviewDraftStore: ReviewDraftStore
    private var loadHistoryTask: Task<Void, Never>?

    init(dataController: DataController, reviewDraftStore: ReviewDraftStore) {
        self.dataController = dataController
        self.reviewDraftStore = reviewDraftStore
    }

    deinit {
        Self.logger.debug("HistoryViewModel deinit: cancelling history load task.")
        loadHistoryTask?.cancel()
    }

    func loadHistory() {
        if loadHistoryTask != nil {
            Self.logger.debug("Cancelling previous history load task before reloading.")
        }
        loadHistoryTask?.cancel()
        isLoading = true

        let container = dataController.container

        loadHistoryTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            Self.logger.debug("Loading history rows and in-progress drafts.")
            async let drafts = reviewDraftStore.list()
            await self.dataController.waitUntilLoaded()
            guard !Task.isCancelled else {
                Self.logger.debug("History load task cancelled before Core Data fetch.")
                return
            }
            let backgroundContext = container.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

            let mapped: [HistoryRow] = await backgroundContext.perform {
                guard NSEntityDescription.entity(forEntityName: "PurchaseOrder", in: backgroundContext) != nil else {
                    return []
                }

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

            let draftSnapshots = await drafts
            guard !Task.isCancelled else {
                Self.logger.debug("History load task cancelled after fetch and before state update.")
                return
            }
            orders = mapped
            inProgressDrafts = draftSnapshots
            isLoading = false
            Self.logger.debug(
                "Loaded history rows=\(mapped.count, privacy: .public) drafts=\(draftSnapshots.count, privacy: .public)."
            )
        }
    }

    func deleteDraft(_ draft: ReviewDraftSnapshot) async {
        do {
            try await reviewDraftStore.delete(id: draft.id)
            inProgressDrafts = await reviewDraftStore.list()
        } catch {
            // Keep this silent in the model; the view already remains stable with current state.
        }
    }

    func purchaseOrder(for row: HistoryRow) -> PurchaseOrder? {
        (try? dataController.viewContext.existingObject(with: row.objectID)) as? PurchaseOrder
    }
}
