//
//  TicketsViewModel.swift
//  POScannerApp
//

import Combine
import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking

@MainActor
final class TicketsViewModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case open = "Open"
        case recent = "Recent"
        case search = "Search"

        var id: String { rawValue }
    }

    @Published var scope: Scope = .open {
        didSet {
            applyFilter()
        }
    }
    @Published var searchText: String = "" {
        didSet {
            applyFilter()
        }
    }

    @Published private(set) var tickets: [TicketModel] = []
    @Published private(set) var filteredTickets: [TicketModel] = []
    @Published private(set) var activeTicketID: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    private let ticketStore: any TicketStoring
    private let shopmonkeyAPI: any ShopmonkeyServicing
    private let dateProvider: any DateProviding
    private let isAuthConfigured: () -> Bool

    private let recentDaysDefault = 30

    init(
        ticketStore: any TicketStoring,
        shopmonkeyAPI: any ShopmonkeyServicing,
        dateProvider: any DateProviding = SystemDateProvider(),
        isAuthConfigured: @escaping () -> Bool = { true }
    ) {
        self.ticketStore = ticketStore
        self.shopmonkeyAPI = shopmonkeyAPI
        self.dateProvider = dateProvider
        self.isAuthConfigured = isAuthConfigured
    }

    func loadCachedState() async {
        activeTicketID = await ticketStore.activeTicketID()
        tickets = await ticketStore.loadOpenTickets()
        lastUpdated = await ticketStore.lastRefreshedAt()
        applyFilter()

        if tickets.isEmpty {
            await refreshForCurrentScope(forceRemote: true)
        }
    }

    func refreshForCurrentScope(forceRemote: Bool = true) async {
        switch scope {
        case .open, .search:
            await refreshOpenTickets(forceRemote: forceRemote)
        case .recent:
            await refreshRecentTickets(days: recentDaysDefault, forceRemote: forceRemote)
        }
    }

    func refreshOpenTickets(forceRemote: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if !forceRemote {
            activeTicketID = await ticketStore.activeTicketID()
            tickets = await ticketStore.loadOpenTickets()
            lastUpdated = await ticketStore.lastRefreshedAt()
            applyFilter()
            return
        }

        do {
            let fetched = try await shopmonkeyAPI.fetchOpenTickets()
            await ticketStore.save(tickets: fetched)
            activeTicketID = await ticketStore.activeTicketID()
            tickets = await ticketStore.loadOpenTickets()
            lastUpdated = await ticketStore.lastRefreshedAt()
            errorMessage = nil
            applyFilter()
        } catch {
            guard !isRequestCancellation(error) else { return }
            activeTicketID = await ticketStore.activeTicketID()
            tickets = await ticketStore.loadOpenTickets()
            lastUpdated = await ticketStore.lastRefreshedAt()
            errorMessage = authErrorMessage(for: error, isAuthConfigured: isAuthConfigured())
                ?? "Could not refresh tickets."
            applyFilter()
        }
    }

    func refreshRecentTickets(days: Int = 30, forceRemote: Bool = true) async {
        if forceRemote {
            await refreshOpenTickets(forceRemote: true)
        } else {
            activeTicketID = await ticketStore.activeTicketID()
            tickets = await ticketStore.loadOpenTickets()
            lastUpdated = await ticketStore.lastRefreshedAt()
        }

        let now = dateProvider.now
        let threshold = now.addingTimeInterval(-TimeInterval(max(1, days)) * 24 * 60 * 60)

        filteredTickets = tickets
            .filter { ticket in
                guard let updatedAt = ticket.updatedAt else { return false }
                return updatedAt >= threshold
            }
            .sorted(by: sortTickets)

        if filteredTickets.isEmpty {
            errorMessage = nil
        }
    }

    func setActiveTicketID(_ ticketID: String?) async {
        await ticketStore.setActiveTicketID(ticketID)
        activeTicketID = await ticketStore.activeTicketID()
        applyFilter()
    }

    func clearActiveTicketContext() async {
        let existingActiveTicketID = await ticketStore.activeTicketID()
        if let existingActiveTicketID {
            await ticketStore.setSelectedServiceID(nil, forTicketID: existingActiveTicketID)
        }
        await ticketStore.setActiveTicketID(nil)
        activeTicketID = await ticketStore.activeTicketID()
        applyFilter()
    }

    func selectedServiceID(for ticketID: String) async -> String? {
        await ticketStore.selectedServiceID(forTicketID: ticketID)
    }

    private func applyFilter() {
        let normalizedQuery = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        switch scope {
        case .open:
            filteredTickets = tickets.sorted(by: sortTickets)

        case .recent:
            let now = dateProvider.now
            let threshold = now.addingTimeInterval(-TimeInterval(recentDaysDefault) * 24 * 60 * 60)
            filteredTickets = tickets
                .filter { ticket in
                    guard let updatedAt = ticket.updatedAt else { return false }
                    return updatedAt >= threshold
                }
                .sorted(by: sortTickets)

        case .search:
            if normalizedQuery.isEmpty {
                filteredTickets = tickets.sorted(by: sortTickets)
            } else {
                filteredTickets = tickets
                    .filter { ticket in
                        let searchableFields = [
                            ticket.displayNumber,
                            ticket.number,
                            ticket.customerName,
                            ticket.vehicleSummary,
                            ticket.status,
                            ticket.id
                        ]

                        return searchableFields.compactMap { $0 }
                            .map {
                                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                                    .lowercased()
                            }
                            .contains(where: { $0.contains(normalizedQuery) })
                    }
                    .sorted(by: sortTickets)
            }
        }
    }

    private func sortTickets(lhs: TicketModel, rhs: TicketModel) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }

        let lhsDisplay = lhs.displayNumber ?? lhs.number ?? lhs.id
        let rhsDisplay = rhs.displayNumber ?? rhs.number ?? rhs.id
        return lhsDisplay.localizedCaseInsensitiveCompare(rhsDisplay) == .orderedAscending
    }
}
