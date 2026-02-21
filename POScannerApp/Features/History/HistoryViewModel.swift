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
        let statusBucket: PurchaseOrderStatusBucket
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
    private let reviewDraftStore: any ReviewDraftStoring
    private var loadHistoryTask: Task<Void, Never>?
    private var pendingHistoryReload: Bool = false
    private var lastHistoryLoadAt: Date?
    private let minimumHistoryReloadInterval: TimeInterval = 1.0

    init(dataController: DataController, reviewDraftStore: any ReviewDraftStoring) {
        self.dataController = dataController
        self.reviewDraftStore = reviewDraftStore
    }

    deinit {
        Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.History")
            .debug("HistoryViewModel deinit: cancelling history load task.")
        loadHistoryTask?.cancel()
    }

    func loadHistory() {
        if loadHistoryTask != nil {
            if !pendingHistoryReload {
                pendingHistoryReload = true
                Self.logger.debug("Queued history reload while existing load is active.")
            }
            return
        }
        if let lastHistoryLoadAt,
           Date().timeIntervalSince(lastHistoryLoadAt) < minimumHistoryReloadInterval {
            return
        }
        isLoading = true

        let container = dataController.container

        loadHistoryTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                loadHistoryTask = nil
                if pendingHistoryReload {
                    pendingHistoryReload = false
                    loadHistory()
                }
            }
            Self.logger.debug("Loading history rows and in-progress drafts.")
            async let drafts = reviewDraftStore.list()
            await self.dataController.waitUntilLoaded()
            guard !Task.isCancelled else {
                Self.logger.debug("History load task cancelled before Core Data fetch.")
                return
            }
            let backgroundContext = container.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

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
                        statusBucket: PurchaseOrderStatusBucket.from(order),
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
            publishWidgetSnapshot(orders: mapped, drafts: draftSnapshots)
            lastHistoryLoadAt = Date()
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

    private func publishWidgetSnapshot(orders: [HistoryRow], drafts: [ReviewDraftSnapshot]) {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todayOrders = orders.filter { $0.date >= startOfDay && $0.statusBucket.countsAsTrackedScan }
        let scansToday = todayOrders.count
        let submitted = todayOrders.filter { $0.statusBucket == .submitted }.count
        let pending = todayOrders.filter { $0.statusBucket == .pending }.count
        let failed = todayOrders.filter { $0.statusBucket == .failed }.count
        let total = todayOrders.reduce(Decimal.zero) { partial, row in
            partial + Decimal(row.totalAmount)
        }
        let reviewCount = drafts.filter {
            switch $0.workflowState {
            case .reviewReady, .reviewEdited, .failed:
                return true
            case .scanning, .ocrReview, .parsing, .submitting:
                return false
            }
        }.count

        PartsIntakeWidgetBridge.publish(
            scansToday: scansToday,
            submittedCount: submitted,
            failedCount: failed,
            pendingCount: pending,
            draftCount: drafts.count,
            reviewCount: reviewCount,
            totalValue: total
        )
    }
}
