//
//  TicketStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

protocol TicketStoring: Sendable {
    func save(ticket: TicketModel) async
    func save(tickets: [TicketModel]) async
    func loadTicket(id: String) async -> TicketModel?
    func loadOpenTickets() async -> [TicketModel]
    func clear() async
}

actor TicketStore: TicketStoring {
    private struct PersistedState: Codable {
        var tickets: [TicketModel]
    }

    private let fileURL: URL?
    private var hasLoadedState = false
    private var ticketsByID: [String: TicketModel] = [:]

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

    func clear() async {
        loadStateIfNeeded()
        ticketsByID.removeAll(keepingCapacity: false)
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
    }

    private func persistStateIfNeeded() {
        guard let fileURL else { return }
        let persisted = PersistedState(tickets: Array(ticketsByID.values).sorted(by: Self.sortTickets))

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
}
