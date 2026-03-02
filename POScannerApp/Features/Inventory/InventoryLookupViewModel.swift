//
//  InventoryLookupViewModel.swift
//  POScannerApp
//

import Combine
import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync

@MainActor
final class InventoryLookupViewModel: ObservableObject {
    private static let supportsRemoteQuantityIncrement = false
    private static let mutationStalenessThreshold: TimeInterval = 10 * 60

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
    private let serviceResolver: (@Sendable (String) async throws -> [ServiceSummary])?

    init(
        inventoryStore: InventoryStoring,
        ticketStore: any TicketStoring = TicketStore(),
        purchaseOrderStore: any PurchaseOrderStoring = PurchaseOrderStore(),
        syncOperationQueue: SyncOperationQueueStore = .shared,
        syncEngine: SyncEngine? = nil,
        dateProvider: any DateProviding = SystemDateProvider(),
        serviceResolver: (@Sendable (String) async throws -> [ServiceSummary])? = nil
    ) {
        self.inventoryStore = inventoryStore
        self.ticketStore = ticketStore
        self.purchaseOrderStore = purchaseOrderStore
        self.syncOperationQueue = syncOperationQueue
        self.dateProvider = dateProvider
        self.serviceResolver = serviceResolver
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

        let matchedInventoryItem = await inventoryStore.lookupItem(scannedCode: exactScannedCode)
        if let matchedInventoryItem {
            state = .matchFound(matchedInventoryItem)
        } else {
            state = .noMatch
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

        guard let serviceID = await resolveServiceID(for: ticketID) else {
            ticketMutationState = .failed(diagnosticCode: nil)
            if ticketMutationMessage == nil {
                ticketMutationMessage = "Select a ticket service before adding inventory."
            }
            lastTicketMutationOperationID = nil
            return
        }

        guard let vendorID = Self.trimmed(item.vendorId) else {
            ticketMutationState = .failed(diagnosticCode: nil)
            ticketMutationMessage = "This inventory item is missing a vendor. Select or refresh inventory before adding."
            lastTicketMutationOperationID = nil
            return
        }

        let ticketDataIsStale = await ticketStore.isStale(
            now: dateProvider.now,
            threshold: Self.mutationStalenessThreshold
        )
        if ticketDataIsStale {
            ticketMutationState = .failed(diagnosticCode: nil)
            ticketMutationMessage = "Ticket data may be stale. Refresh tickets before proceeding."
            lastTicketMutationOperationID = nil
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
            serviceID: serviceID,
            sku: Self.trimmed(item.sku),
            partNumber: Self.trimmed(item.partNumber),
            description: item.description,
            quantity: 1,
            unitPrice: item.price,
            vendorID: vendorID,
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
            if persisted.lastErrorCode == DiagnosticCode.submitValidatePayload.rawValue {
                ticketMutationMessage = "Ticket context changed. Re-run add action after selecting a service."
            } else if let code = persisted.lastErrorCode {
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
        var suggestion = ScanSuggestionEngine.suggest(
            scannedCode: scannedCode,
            inventoryMatch: inventoryMatch,
            activeTicket: activeTicket,
            openPurchaseOrders: openPurchaseOrders
        )

        let now = dateProvider.now
        let inventoryIsStale = await inventoryStore.isStale(now: now, threshold: Self.mutationStalenessThreshold)
        let ticketIsStale = await ticketStore.isStale(now: now, threshold: Self.mutationStalenessThreshold)
        let purchaseOrdersAreStale = await purchaseOrderStore.isStale(now: now, threshold: Self.mutationStalenessThreshold)

        switch suggestion {
        case .receivePO:
            if purchaseOrdersAreStale {
                suggestion = .none
                draftMutationMessage = "Purchase order data may be stale. Refresh purchase orders before receiving."
            }
        case .addToTicket:
            if ticketIsStale {
                suggestion = .none
                ticketMutationMessage = "Ticket data may be stale. Refresh tickets before adding."
            }
        case .addToPODraft:
            if inventoryIsStale {
                suggestion = .none
                draftMutationMessage = "Inventory data may be stale. Refresh inventory before restocking."
            }
        case .none:
            break
        }
        scanSuggestion = suggestion
    }

    private func resolveServiceID(for ticketID: String) async -> String? {
        if let cached = await ticketStore.selectedServiceID(forTicketID: ticketID) {
            return cached
        }

        guard let serviceResolver else {
            ticketMutationMessage = "No cached service for this ticket. Select one in Tickets first."
            return nil
        }

        do {
            let services = try await serviceResolver(ticketID)
            let normalizedServices = services.compactMap { service -> ServiceSummary? in
                guard let id = Self.trimmed(service.id) else { return nil }
                return ServiceSummary(id: id, name: service.name)
            }

            if normalizedServices.count == 1, let only = normalizedServices.first {
                await ticketStore.setSelectedServiceID(only.id, forTicketID: ticketID)
                return only.id
            }

            if normalizedServices.isEmpty {
                ticketMutationMessage = "No services found for this ticket. Select a different ticket."
            } else {
                ticketMutationMessage = "Multiple services found. Select one from Tickets before adding items."
            }
            return nil
        } catch {
            ticketMutationMessage = "Unable to load ticket services while offline. Select a cached service first."
            return nil
        }
    }
}
