//
//  InventoryLookupViewModel.swift
//  POScannerApp
//

import Combine
import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreSync

@MainActor
final class InventoryLookupViewModel: ObservableObject {
    private static let supportsRemoteQuantityIncrement = false

    enum State: Equatable {
        case idle
        case scanning
        case matchFound(InventoryItem)
        case noMatch
        case error(String)
    }

    enum TicketMutationState: Equatable {
        case idle
        case adding
        case succeeded
        case queued(diagnosticCode: String?)
        case failed(diagnosticCode: String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var scannedCode: String?
    @Published private(set) var ticketMutationState: TicketMutationState = .idle
    @Published private(set) var ticketMutationMessage: String?
    @Published private(set) var draftMutationMessage: String?
    @Published private(set) var lastTicketMutationOperationID: UUID?
    @Published private(set) var scanSuggestion: ScanSuggestion = .none

    private let inventoryStore: InventoryStoring
    private let ticketStore: any TicketStoring
    private let purchaseOrderStore: any PurchaseOrderStoring
    private let syncOperationQueue: SyncOperationQueueStore
    private let syncEngine: SyncEngine
    private let dateProvider: any DateProviding

    init(
        inventoryStore: InventoryStoring,
        ticketStore: any TicketStoring = TicketStore(),
        purchaseOrderStore: any PurchaseOrderStoring = PurchaseOrderStore(),
        syncOperationQueue: SyncOperationQueueStore = .shared,
        syncEngine: SyncEngine? = nil,
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.inventoryStore = inventoryStore
        self.ticketStore = ticketStore
        self.purchaseOrderStore = purchaseOrderStore
        self.syncOperationQueue = syncOperationQueue
        self.dateProvider = dateProvider
        self.syncEngine = syncEngine ?? SyncEngine(
            queueStore: syncOperationQueue,
            executor: { _ in .succeeded }
        )
    }

    func startScanning() {
        state = .scanning
        ticketMutationState = .idle
        ticketMutationMessage = nil
        draftMutationMessage = nil
        scanSuggestion = .none
    }

    func setScannerUnavailable() {
        state = .error("Scanner unavailable on this device.")
        scanSuggestion = .none
    }

    func reset() {
        scannedCode = nil
        state = .idle
        ticketMutationState = .idle
        ticketMutationMessage = nil
        draftMutationMessage = nil
        lastTicketMutationOperationID = nil
        scanSuggestion = .none
    }

    func lookup(scannedCode rawCode: String?) async {
        let exactScannedCode = Self.trimmed(rawCode)
        self.scannedCode = exactScannedCode
        ticketMutationState = .idle
        ticketMutationMessage = nil
        draftMutationMessage = nil

        guard let exactScannedCode else {
            state = .idle
            scanSuggestion = .none
            return
        }

        let items = await inventoryStore.allItems()
        var matchedInventoryItem: InventoryItem?

        if let exactSkuMatch = items.first(where: {
            Self.trimmed($0.sku) == exactScannedCode
        }) {
            state = .matchFound(exactSkuMatch)
            matchedInventoryItem = exactSkuMatch
        }

        if matchedInventoryItem == nil,
           let exactPartNumberMatch = items.first(where: {
            Self.trimmed($0.partNumber) == exactScannedCode
        }) {
            state = .matchFound(exactPartNumberMatch)
            matchedInventoryItem = exactPartNumberMatch
        }

        if matchedInventoryItem == nil {
            if let normalizedScannedCode = Self.normalized(exactScannedCode),
               let normalizedMatch = items.first(where: { item in
                   Self.normalized(item.sku) == normalizedScannedCode ||
                   Self.normalized(item.partNumber) == normalizedScannedCode
               }) {
                state = .matchFound(normalizedMatch)
                matchedInventoryItem = normalizedMatch
            } else {
                state = .noMatch
            }
        }

        await refreshSuggestion(scannedCode: exactScannedCode, inventoryMatch: matchedInventoryItem)
    }

    func hasDuplicateMatch(in ticketID: String) async -> Bool {
        guard case .matchFound(let item) = state else { return false }
        return await ticketStore.hasMatchingLineItem(
            ticketID: ticketID,
            sku: Self.trimmed(item.sku),
            partNumber: Self.trimmed(item.partNumber),
            description: item.description
        )
    }

    func addMatchedItemToTicket(
        ticketID rawTicketID: String?,
        mergeMode: TicketLineMergeMode
    ) async {
        guard case .matchFound(let item) = state else {
            ticketMutationState = .failed(diagnosticCode: nil)
            ticketMutationMessage = "Scan an inventory item before adding to a ticket."
            return
        }

        guard let ticketID = Self.trimmed(rawTicketID) else {
            ticketMutationState = .failed(diagnosticCode: nil)
            ticketMutationMessage = "Select an active ticket before adding."
            return
        }

        if mergeMode == .incrementQuantity, !Self.supportsRemoteQuantityIncrement {
            ticketMutationState = .failed(diagnosticCode: nil)
            ticketMutationMessage = "Increment quantity is unavailable until ticket line updates are supported. Choose Add New Line."
            lastTicketMutationOperationID = nil
            return
        }

        let payload = TicketLineItemMutationPayload(
            ticketID: ticketID,
            sku: Self.trimmed(item.sku),
            partNumber: Self.trimmed(item.partNumber),
            description: item.description,
            quantity: 1,
            unitPrice: item.price,
            mergeMode: mergeMode
        )

        let operation = SyncOperation(
            id: UUID(),
            type: .addTicketLineItem,
            payloadFingerprint: payload.payloadFingerprint,
            status: .pending,
            retryCount: 0,
            createdAt: dateProvider.now
        )

        ticketMutationState = .adding
        ticketMutationMessage = nil
        lastTicketMutationOperationID = operation.id
        _ = await syncOperationQueue.enqueue(operation)
        await syncEngine.runOnce()

        guard let persisted = await syncOperationQueue.operation(id: operation.id) else {
            ticketMutationState = .succeeded
            ticketMutationMessage = "Added to ticket."
            return
        }

        switch persisted.status {
        case .pending, .inProgress:
            ticketMutationState = .queued(diagnosticCode: persisted.lastErrorCode)
            ticketMutationMessage = "Queued for retry."
        case .failed:
            ticketMutationState = .failed(diagnosticCode: persisted.lastErrorCode)
            if let code = persisted.lastErrorCode {
                ticketMutationMessage = "Could not add to ticket. (ID: \(code))"
            } else {
                ticketMutationMessage = "Could not add to ticket."
            }
        case .succeeded:
            ticketMutationState = .succeeded
            ticketMutationMessage = "Added to ticket."
            await syncOperationQueue.remove(id: operation.id)
        }
    }

    func matchedItemDraftLine() -> PurchaseOrderDraftLine? {
        guard case .matchFound(let item) = state else { return nil }
        return PurchaseOrderDraftLine(
            sku: Self.trimmed(item.sku),
            partNumber: Self.trimmed(item.partNumber),
            description: item.description,
            quantity: 1,
            unitCost: item.price > .zero ? item.price : nil,
            sourceBarcode: scannedCode
        )
    }

    func manualDraftLine(
        description: String,
        quantity: Decimal,
        unitCost: Decimal?
    ) -> PurchaseOrderDraftLine? {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { return nil }
        return PurchaseOrderDraftLine(
            description: trimmedDescription,
            quantity: max(1, quantity),
            unitCost: unitCost.map { max(0, $0) },
            sourceBarcode: scannedCode
        )
    }

    func setDraftMutationMessage(_ message: String?) {
        draftMutationMessage = message
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = trimmed(value) else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func refreshSuggestion(scannedCode: String, inventoryMatch: InventoryItem?) async {
        let activeTicket = await ticketStore.loadActiveTicket()
        let openPurchaseOrders = await purchaseOrderStore.loadOpenPurchaseOrderDetails()
        scanSuggestion = ScanSuggestionEngine.suggest(
            scannedCode: scannedCode,
            inventoryMatch: inventoryMatch,
            activeTicket: activeTicket,
            openPurchaseOrders: openPurchaseOrders
        )
    }
}
