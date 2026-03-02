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
    @discardableResult
    func saveOpenTicketsPage(page: Int, tickets: [TicketModel], pageSize: Int, refreshedAt: Date) async -> Bool
    func loadTicket(id: String) async -> TicketModel?
    func loadOpenTicketsPage(page: Int, pageSize: Int) async -> [TicketModel]
    func loadOpenTickets() async -> [TicketModel]
    func openTicketCount() async -> Int
    func lastRefreshedAt() async -> Date?
    func isStale(now: Date, threshold: TimeInterval) async -> Bool
    func activeTicketID() async -> String?
    func loadActiveTicket() async -> TicketModel?
    func setActiveTicketID(_ id: String?) async
    func selectedServiceID(forTicketID ticketID: String) async -> String?
    func setSelectedServiceID(_ serviceID: String?, forTicketID ticketID: String) async
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

extension TicketStoring {
    @discardableResult
    func saveOpenTicketsPage(
        page: Int,
        tickets: [TicketModel],
        pageSize: Int = 50,
        refreshedAt: Date = Date()
    ) async -> Bool {
        _ = page
        _ = pageSize
        _ = refreshedAt
        await save(tickets: tickets)
        return true
    }

    func loadOpenTicketsPage(page: Int, pageSize: Int = 50) async -> [TicketModel] {
        guard page >= 0, pageSize > 0 else { return [] }
        let openTickets = await loadOpenTickets()
        let start = page * pageSize
        guard start < openTickets.count else { return [] }
        let end = min(openTickets.count, start + pageSize)
        return Array(openTickets[start..<end])
    }

    func openTicketCount() async -> Int {
        await loadOpenTickets().count
    }

    func lastRefreshedAt() async -> Date? { nil }

    func isStale(now: Date, threshold: TimeInterval) async -> Bool {
        _ = now
        _ = threshold
        return true
    }

    func selectedServiceID(forTicketID ticketID: String) async -> String? {
        _ = ticketID
        return nil
    }

    func setSelectedServiceID(_ serviceID: String?, forTicketID ticketID: String) async {
        _ = serviceID
        _ = ticketID
    }
}

actor TicketStore: TicketStoring {
    static let defaultPageSize = 50
    static let maxCacheTickets = 300

    private struct PersistedState: Codable {
        var tickets: [TicketModel]
        var activeTicketID: String?
        var lastRefreshedAt: Date?
        var selectedServiceByTicketID: [String: String]?
    }

    private let fileURL: URL?
    private var hasLoadedState = false
    private var ticketsByID: [String: TicketModel] = [:]
    private var selectedActiveTicketID: String?
    private var lastRefreshedAtValue: Date?
    private var selectedServiceByTicketID: [String: String] = [:]
    private var inFlightPages: Set<Int> = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func save(ticket: TicketModel) async {
        loadStateIfNeeded()
        let normalizedTicket = normalize(ticket: ticket)
        let key = normalizedID(normalizedTicket.id)
        guard !key.isEmpty else { return }
        ticketsByID[key] = normalizedTicket
        if lastRefreshedAtValue == nil {
            lastRefreshedAtValue = normalizedTicket.updatedAt ?? Date()
        }
        enforceOpenTicketCap()
        persistStateIfNeeded()
    }

    func save(tickets: [TicketModel]) async {
        loadStateIfNeeded()
        ticketsByID = tickets.reduce(into: [:]) { partialResult, ticket in
            let normalizedTicket = normalize(ticket: ticket)
            let key = normalizedID(normalizedTicket.id)
            guard !key.isEmpty else { return }
            partialResult[key] = normalizedTicket
        }
        lastRefreshedAtValue = Date()
        enforceOpenTicketCap()
        if let selectedActiveTicketID,
           ticketsByID[selectedActiveTicketID] == nil {
            self.selectedActiveTicketID = nil
        }
        selectedServiceByTicketID = selectedServiceByTicketID.filter { ticketsByID[$0.key] != nil }
        persistStateIfNeeded()
    }

    @discardableResult
    func saveOpenTicketsPage(
        page: Int,
        tickets: [TicketModel],
        pageSize: Int = TicketStore.defaultPageSize,
        refreshedAt: Date = Date()
    ) async -> Bool {
        loadStateIfNeeded()
        guard page >= 0 else { return false }
        guard !inFlightPages.contains(page) else { return false }
        inFlightPages.insert(page)
        defer { inFlightPages.remove(page) }

        let normalizedPageSize = max(1, pageSize)
        let normalizedTickets = tickets.map(normalize(ticket:))
        if normalizedTickets.isEmpty && page == 0 {
            ticketsByID.removeAll(keepingCapacity: false)
            selectedActiveTicketID = nil
            lastRefreshedAtValue = refreshedAt
            persistStateIfNeeded()
            return true
        }

        let existingOpenIDs = loadOpenTicketIDsSorted()
        var orderedIDs = existingOpenIDs
        let startIndex = page * normalizedPageSize
        if orderedIDs.count < startIndex {
            orderedIDs.append(contentsOf: Array(repeating: "", count: startIndex - orderedIDs.count))
        }

        for (offset, ticket) in normalizedTickets.enumerated() {
            let key = normalizedID(ticket.id)
            guard !key.isEmpty else { continue }
            let targetIndex = startIndex + offset
            if orderedIDs.count <= targetIndex {
                orderedIDs.append(key)
            } else {
                orderedIDs[targetIndex] = key
            }
            ticketsByID[key] = ticket
        }

        orderedIDs = orderedIDs.filter { !$0.isEmpty }
        if page == 0 && normalizedTickets.count < normalizedPageSize {
            orderedIDs = Array(orderedIDs.prefix(normalizedTickets.count))
        }

        if !orderedIDs.isEmpty {
            let kept = Set(orderedIDs)
            for key in ticketsByID.keys where !kept.contains(key) && isOpenStatus(ticketsByID[key]?.status) {
                ticketsByID.removeValue(forKey: key)
            }
        }

        lastRefreshedAtValue = refreshedAt
        enforceOpenTicketCap()
        if let selectedActiveTicketID,
           ticketsByID[selectedActiveTicketID] == nil {
            self.selectedActiveTicketID = nil
        }
        selectedServiceByTicketID = selectedServiceByTicketID.filter { ticketsByID[$0.key] != nil }
        persistStateIfNeeded()
        return true
    }

    func loadTicket(id: String) async -> TicketModel? {
        loadStateIfNeeded()
        return ticketsByID[normalizedID(id)]
    }

    func loadOpenTicketsPage(page: Int, pageSize: Int = TicketStore.defaultPageSize) async -> [TicketModel] {
        loadStateIfNeeded()
        guard page >= 0, pageSize > 0 else { return [] }
        let openTickets = loadOpenTicketsSorted()
        let start = page * pageSize
        guard start < openTickets.count else { return [] }
        let end = min(openTickets.count, start + pageSize)
        return Array(openTickets[start..<end])
    }

    func loadOpenTickets() async -> [TicketModel] {
        loadStateIfNeeded()
        return loadOpenTicketsSorted()
    }

    func openTicketCount() async -> Int {
        loadStateIfNeeded()
        return loadOpenTicketsSorted().count
    }

    func lastRefreshedAt() async -> Date? {
        loadStateIfNeeded()
        return lastRefreshedAtValue
    }

    func isStale(now: Date, threshold: TimeInterval) async -> Bool {
        loadStateIfNeeded()
        guard let lastRefreshedAtValue else { return true }
        return now.timeIntervalSince(lastRefreshedAtValue) > threshold
    }

    func activeTicketID() async -> String? {
        loadStateIfNeeded()
        return selectedActiveTicketID
    }

    func loadActiveTicket() async -> TicketModel? {
        loadStateIfNeeded()
        guard let selectedActiveTicketID else { return nil }
        return ticketsByID[selectedActiveTicketID]
    }

    func setActiveTicketID(_ id: String?) async {
        loadStateIfNeeded()
        selectedActiveTicketID = normalizedID(id ?? "")
        if selectedActiveTicketID?.isEmpty == true {
            selectedActiveTicketID = nil
        }
        persistStateIfNeeded()
    }

    func selectedServiceID(forTicketID ticketID: String) async -> String? {
        loadStateIfNeeded()
        let key = normalizedID(ticketID)
        guard !key.isEmpty else { return nil }
        return selectedServiceByTicketID[key]
    }

    func setSelectedServiceID(_ serviceID: String?, forTicketID ticketID: String) async {
        loadStateIfNeeded()
        let ticketKey = normalizedID(ticketID)
        guard !ticketKey.isEmpty else { return }

        guard ticketsByID[ticketKey] != nil else {
            selectedServiceByTicketID.removeValue(forKey: ticketKey)
            persistStateIfNeeded()
            return
        }

        let normalizedServiceID = normalizedID(serviceID ?? "")
        if normalizedServiceID.isEmpty {
            selectedServiceByTicketID.removeValue(forKey: ticketKey)
        } else {
            selectedServiceByTicketID[ticketKey] = normalizedServiceID
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
        enforceOpenTicketCap()
        persistStateIfNeeded()
        return ticket
    }

    func clear() async {
        loadStateIfNeeded()
        ticketsByID.removeAll(keepingCapacity: false)
        selectedActiveTicketID = nil
        lastRefreshedAtValue = nil
        selectedServiceByTicketID.removeAll(keepingCapacity: false)
        inFlightPages.removeAll(keepingCapacity: false)
        persistStateIfNeeded()
    }

    func debugTicketIndexCount() async -> Int {
        loadStateIfNeeded()
        return ticketsByID.count
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
            let normalizedTicket = normalize(ticket: ticket)
            let key = normalizedID(normalizedTicket.id)
            guard !key.isEmpty else { return }
            partialResult[key] = normalizedTicket
        }
        selectedActiveTicketID = normalizedID(decoded.activeTicketID ?? "")
        if selectedActiveTicketID?.isEmpty == true {
            selectedActiveTicketID = nil
        }
        lastRefreshedAtValue = decoded.lastRefreshedAt
        selectedServiceByTicketID = (decoded.selectedServiceByTicketID ?? [:]).reduce(into: [:]) { partialResult, entry in
            let ticketKey = normalizedID(entry.key)
            let serviceID = normalizedID(entry.value)
            guard !ticketKey.isEmpty, !serviceID.isEmpty else { return }
            guard ticketsByID[ticketKey] != nil else { return }
            partialResult[ticketKey] = serviceID
        }
        enforceOpenTicketCap()
    }

    private func persistStateIfNeeded() {
        guard let fileURL else { return }
        let persisted = PersistedState(
            tickets: Array(ticketsByID.values).sorted(by: Self.sortTickets),
            activeTicketID: selectedActiveTicketID,
            lastRefreshedAt: lastRefreshedAtValue,
            selectedServiceByTicketID: selectedServiceByTicketID.isEmpty ? nil : selectedServiceByTicketID
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

    private func normalize(ticket: TicketModel) -> TicketModel {
        TicketModel(
            id: normalizedID(ticket.id),
            number: normalizedOptional(ticket.number),
            displayNumber: normalizedOptional(ticket.displayNumber),
            status: normalizedOptional(ticket.status),
            customerName: normalizedOptional(ticket.customerName),
            vehicleSummary: normalizedOptional(ticket.vehicleSummary),
            updatedAt: ticket.updatedAt,
            lineItems: ticket.lineItems
        )
    }

    private func loadOpenTicketsSorted() -> [TicketModel] {
        ticketsByID.values
            .filter { isOpenStatus($0.status) }
            .sorted(by: Self.sortTickets)
    }

    private func loadOpenTicketIDsSorted() -> [String] {
        loadOpenTicketsSorted().map { normalizedID($0.id) }
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

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func enforceOpenTicketCap() {
        let openTickets = loadOpenTicketsSorted()
        guard openTickets.count > Self.maxCacheTickets else { return }

        let keepIDs = Set(openTickets.prefix(Self.maxCacheTickets).map { normalizedID($0.id) })
        let evictedIDs = Set(openTickets.dropFirst(Self.maxCacheTickets).map { normalizedID($0.id) })

        for key in evictedIDs {
            ticketsByID.removeValue(forKey: key)
        }

        if let selectedActiveTicketID,
           !keepIDs.contains(selectedActiveTicketID) {
            self.selectedActiveTicketID = nil
        }
        selectedServiceByTicketID = selectedServiceByTicketID.filter { keepIDs.contains($0.key) }
    }
}
