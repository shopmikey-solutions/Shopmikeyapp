//
//  TicketStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

enum TicketLineMergeMode: String, Codable, Sendable {
    case incrementQuantity
    case addNewLine
}

protocol TicketStoring: Sendable {
    func save(ticket: TicketModel) async
    func save(tickets: [TicketModel]) async
    func loadTicket(id: String) async -> TicketModel?
    func loadOpenTickets() async -> [TicketModel]
    func activeTicketID() async -> String?
    func setActiveTicketID(_ id: String?) async
    func hasMatchingLineItem(ticketID: String, sku: String?, partNumber: String?, description: String?) async -> Bool
    func findMatchingLineItem(ticketID: String, sku: String?, partNumber: String?, description: String?) async -> TicketLineItem?
    func applyAddedLineItem(
        _ lineItem: TicketLineItem,
        toTicketID ticketID: String,
        mergeMode: TicketLineMergeMode,
        updatedAt: Date
    ) async -> TicketModel?
    func clear() async
}

actor TicketStore: TicketStoring {
    private struct PersistedState: Codable {
        var tickets: [TicketModel]
        var activeTicketID: String?
    }

    private let fileURL: URL?
    private var hasLoadedState = false
    private var ticketsByID: [String: TicketModel] = [:]
    private var selectedActiveTicketID: String?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func save(ticket: TicketModel) async {
        loadStateIfNeeded()
        let key = normalizedID(ticket.id)
        guard !key.isEmpty else { return }
        ticketsByID[key] = ticket
        persistStateIfNeeded()
    }

    func save(tickets: [TicketModel]) async {
        loadStateIfNeeded()
        ticketsByID = tickets.reduce(into: [:]) { partialResult, ticket in
            let key = normalizedID(ticket.id)
            guard !key.isEmpty else { return }
            partialResult[key] = ticket
        }
        if let selectedActiveTicketID,
           ticketsByID[selectedActiveTicketID] == nil {
            self.selectedActiveTicketID = nil
        }
        persistStateIfNeeded()
    }

    func loadTicket(id: String) async -> TicketModel? {
        loadStateIfNeeded()
        return ticketsByID[normalizedID(id)]
    }

    func loadOpenTickets() async -> [TicketModel] {
        loadStateIfNeeded()
        return ticketsByID.values
            .filter { isOpenStatus($0.status) }
            .sorted(by: Self.sortTickets)
    }

    func activeTicketID() async -> String? {
        loadStateIfNeeded()
        return selectedActiveTicketID
    }

    func setActiveTicketID(_ id: String?) async {
        loadStateIfNeeded()
        selectedActiveTicketID = normalizedID(id ?? "")
        if selectedActiveTicketID?.isEmpty == true {
            selectedActiveTicketID = nil
        }
        persistStateIfNeeded()
    }

    func hasMatchingLineItem(ticketID: String, sku: String?, partNumber: String?, description: String?) async -> Bool {
        await findMatchingLineItem(
            ticketID: ticketID,
            sku: sku,
            partNumber: partNumber,
            description: description
        ) != nil
    }

    func findMatchingLineItem(ticketID: String, sku: String?, partNumber: String?, description: String?) async -> TicketLineItem? {
        loadStateIfNeeded()
        let key = normalizedID(ticketID)
        guard let ticket = ticketsByID[key] else { return nil }
        guard let duplicateIndex = duplicateLineIndex(
            in: ticket,
            sku: normalizedComparable(sku),
            partNumber: normalizedComparable(partNumber),
            description: normalizedComparable(description)
        ) else {
            return nil
        }
        return ticket.lineItems[duplicateIndex]
    }

    func applyAddedLineItem(
        _ lineItem: TicketLineItem,
        toTicketID ticketID: String,
        mergeMode: TicketLineMergeMode,
        updatedAt: Date
    ) async -> TicketModel? {
        loadStateIfNeeded()
        let ticketKey = normalizedID(ticketID)
        guard !ticketKey.isEmpty else { return nil }

        var ticket = ticketsByID[ticketKey] ?? TicketModel(id: ticketKey, updatedAt: updatedAt)
        var updatedLineItems = ticket.lineItems

        if mergeMode == .incrementQuantity,
           let duplicateIndex = duplicateLineIndex(
               in: ticket,
               sku: normalizedComparable(lineItem.sku),
               partNumber: normalizedComparable(lineItem.partNumber),
               description: normalizedComparable(lineItem.description)
           ) {
            var existing = updatedLineItems[duplicateIndex]
            existing.quantity += lineItem.quantity
            if existing.unitPrice == nil {
                existing.unitPrice = lineItem.unitPrice
            }
            if let unitPrice = existing.unitPrice {
                existing.extendedPrice = unitPrice * existing.quantity
            } else if let existingExtendedPrice = existing.extendedPrice {
                existing.extendedPrice = existingExtendedPrice + (lineItem.extendedPrice ?? 0)
            } else {
                existing.extendedPrice = lineItem.extendedPrice
            }
            updatedLineItems[duplicateIndex] = existing
        } else {
            updatedLineItems.append(lineItem)
        }

        ticket.lineItems = updatedLineItems
        ticket.updatedAt = updatedAt
        ticketsByID[ticketKey] = ticket
        persistStateIfNeeded()
        return ticket
    }

    func clear() async {
        loadStateIfNeeded()
        ticketsByID.removeAll(keepingCapacity: false)
        selectedActiveTicketID = nil
        persistStateIfNeeded()
    }

    private func loadStateIfNeeded() {
        guard !hasLoadedState else { return }
        hasLoadedState = true

        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }

        ticketsByID = decoded.tickets.reduce(into: [:]) { partialResult, ticket in
            let key = normalizedID(ticket.id)
            guard !key.isEmpty else { return }
            partialResult[key] = ticket
        }
        selectedActiveTicketID = normalizedID(decoded.activeTicketID ?? "")
        if selectedActiveTicketID?.isEmpty == true {
            selectedActiveTicketID = nil
        }
    }

    private func persistStateIfNeeded() {
        guard let fileURL else { return }
        let persisted = PersistedState(
            tickets: Array(ticketsByID.values).sorted(by: Self.sortTickets),
            activeTicketID: selectedActiveTicketID
        )

        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep ticket caching best-effort and non-blocking.
        }
    }

    private func normalizedID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isOpenStatus(_ status: String?) -> Bool {
        guard let status else { return true }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let closedStatuses: Set<String> = [
            "closed",
            "complete",
            "completed",
            "paid",
            "cancelled",
            "canceled",
            "archived"
        ]
        return !closedStatuses.contains(normalized)
    }

    private static func sortTickets(lhs: TicketModel, rhs: TicketModel) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        if lhs.displayNumber != rhs.displayNumber {
            return (lhs.displayNumber ?? lhs.number ?? lhs.id)
                .localizedCaseInsensitiveCompare(rhs.displayNumber ?? rhs.number ?? rhs.id) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func duplicateLineIndex(
        in ticket: TicketModel,
        sku: String?,
        partNumber: String?,
        description: String?
    ) -> Int? {
        if let sku, !sku.isEmpty,
           let skuMatch = ticket.lineItems.firstIndex(where: { lineItem in
               normalizedComparable(lineItem.sku) == sku
           }) {
            return skuMatch
        }

        if let partNumber, !partNumber.isEmpty,
           let partMatch = ticket.lineItems.firstIndex(where: { lineItem in
               normalizedComparable(lineItem.partNumber) == partNumber
           }) {
            return partMatch
        }

        guard (sku == nil || sku?.isEmpty == true),
              (partNumber == nil || partNumber?.isEmpty == true),
              let description,
              !description.isEmpty else {
            return nil
        }

        return ticket.lineItems.firstIndex { lineItem in
            let lineSKU = normalizedComparable(lineItem.sku)
            let linePartNumber = normalizedComparable(lineItem.partNumber)
            let lineDescription = normalizedComparable(lineItem.description)

            guard lineSKU == nil, linePartNumber == nil else { return false }
            return lineDescription == description
        }
    }

    private func normalizedComparable(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}
