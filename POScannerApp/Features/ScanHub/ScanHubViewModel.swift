//
//  ScanHubViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import ShopmikeyCoreModels

@MainActor
final class ScanHubViewModel: ObservableObject {
    @Published private(set) var lastScannedCode: String?
    @Published private(set) var scanSuggestion: ScanSuggestion = .none
    @Published private(set) var activeTicketLabel: String?
    @Published private(set) var activeServiceID: String?
    @Published private(set) var activeReceivingPurchaseOrderID: String?
    @Published private(set) var lastInventorySyncAt: Date?
    @Published private(set) var openTicketCount: Int = 0
    @Published private(set) var openPurchaseOrderCount: Int = 0
    @Published private(set) var inProgressDraftCount: Int = 0
    @Published private(set) var latestDraftSummary: String?

    private let inventoryStore: InventoryStoring
    private let ticketStore: any TicketStoring
    private let purchaseOrderStore: any PurchaseOrderStoring
    private let reviewDraftStore: any ReviewDraftStoring

    init(
        inventoryStore: InventoryStoring,
        ticketStore: any TicketStoring,
        purchaseOrderStore: any PurchaseOrderStoring,
        reviewDraftStore: any ReviewDraftStoring
    ) {
        self.inventoryStore = inventoryStore
        self.ticketStore = ticketStore
        self.purchaseOrderStore = purchaseOrderStore
        self.reviewDraftStore = reviewDraftStore
    }

    func loadInitialState() async {
        await refreshContext()
        await refreshRecentActivity()
    }

    func refreshContext() async {
        let activeTicket = await ticketStore.loadActiveTicket()
        activeTicketLabel = activeTicket.map { ticket in
            ticket.displayNumber ?? ticket.number ?? ticket.id
        }
        if let activeTicket {
            activeServiceID = await ticketStore.selectedServiceID(forTicketID: activeTicket.id)
        } else {
            activeServiceID = nil
        }

        lastInventorySyncAt = await inventoryStore.lastUpdatedAt()
        openTicketCount = await ticketStore.openTicketCount()
        openPurchaseOrderCount = await purchaseOrderStore.openPurchaseOrderCount()
    }

    func refreshRecentActivity() async {
        let drafts = await reviewDraftStore.list()
        inProgressDraftCount = drafts.count
        latestDraftSummary = drafts.first.map { draft in
            "\(draft.displayVendorName) • \(draft.workflowState.statusLabel)"
        }
    }

    func handleScannedCode(_ rawCode: String?) async {
        guard let normalizedCode = Self.normalized(rawCode) else {
            lastScannedCode = nil
            scanSuggestion = .none
            return
        }

        lastScannedCode = normalizedCode

        let inventoryMatch = await inventoryStore.lookupItem(scannedCode: normalizedCode)
        let activeTicket = await ticketStore.loadActiveTicket()
        let openPurchaseOrders = await purchaseOrderStore.loadOpenPurchaseOrderDetails()

        let suggestion = ScanSuggestionEngine.suggest(
            scannedCode: normalizedCode,
            inventoryMatch: inventoryMatch,
            activeTicket: activeTicket,
            openPurchaseOrders: openPurchaseOrders
        )
        scanSuggestion = suggestion
        if case .receivePO(let purchaseOrderID, _) = suggestion {
            activeReceivingPurchaseOrderID = purchaseOrderID
        }
    }

    func clearLastScan() {
        lastScannedCode = nil
        scanSuggestion = .none
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
