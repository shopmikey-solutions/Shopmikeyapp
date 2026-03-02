//
//  TicketsViewModelTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import Testing
@testable import POScannerApp

private struct TicketsDateProvider: DateProviding {
    let date: Date
    var now: Date { date }
}

private actor TicketServiceStubState {
    var openTickets: [TicketModel] = []

    func setOpenTickets(_ tickets: [TicketModel]) {
        openTickets = tickets
    }

    func getOpenTickets() -> [TicketModel] {
        openTickets
    }
}

private struct TicketsShopmonkeyStub: ShopmonkeyServicing {
    let state: TicketServiceStubState

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        .init(id: "vendor_1", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        _ = orderId
        _ = serviceId
        return .init(id: "part_1", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
    func fetchOrders() async throws -> [OrderSummary] { [] }
    func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
    func searchVendors(name: String) async throws -> [VendorSummary] { [] }
    func testConnection() async throws {}

    func fetchOpenTickets() async throws -> [TicketModel] {
        await state.getOpenTickets()
    }

    func fetchTicket(id: String) async throws -> TicketModel {
        if let exact = await state.getOpenTickets().first(where: { $0.id == id }) {
            return exact
        }
        return TicketModel(id: id)
    }

    func fetchInventory() async throws -> [InventoryItem] { [] }
}

@MainActor
@Suite(.serialized)
struct TicketsViewModelTests {
    private func makeTicket(id: String, number: String, updatedAt: Date) -> TicketModel {
        TicketModel(
            id: id,
            number: number,
            displayNumber: number,
            status: "Open",
            customerName: "Customer \(number)",
            vehicleSummary: "Vehicle \(number)",
            updatedAt: updatedAt,
            lineItems: []
        )
    }

    @Test func loadCachedStateUsesTicketStoreAndActiveTicket() async {
        let now = Date(timeIntervalSince1970: 1_772_900_000)
        let ticketStore = TicketStore()
        let serviceState = TicketServiceStubState()
        let api = TicketsShopmonkeyStub(state: serviceState)

        let cached = [
            makeTicket(id: "ticket_1", number: "RO-1001", updatedAt: now),
            makeTicket(id: "ticket_2", number: "RO-1002", updatedAt: now.addingTimeInterval(-60))
        ]
        await ticketStore.save(tickets: cached)
        await ticketStore.setActiveTicketID("ticket_2")

        let viewModel = TicketsViewModel(
            ticketStore: ticketStore,
            shopmonkeyAPI: api,
            dateProvider: TicketsDateProvider(date: now)
        )

        await viewModel.loadCachedState()

        #expect(viewModel.tickets.count == 2)
        #expect(viewModel.filteredTickets.count == 2)
        #expect(viewModel.activeTicketID == "ticket_2")
    }

    @Test func refreshOpenTicketsPersistsFetchedData() async {
        let now = Date(timeIntervalSince1970: 1_772_900_100)
        let ticketStore = TicketStore()
        let serviceState = TicketServiceStubState()
        let api = TicketsShopmonkeyStub(state: serviceState)

        await serviceState.setOpenTickets([
            makeTicket(id: "ticket_10", number: "RO-2010", updatedAt: now),
            makeTicket(id: "ticket_11", number: "RO-2011", updatedAt: now.addingTimeInterval(-30))
        ])

        let viewModel = TicketsViewModel(
            ticketStore: ticketStore,
            shopmonkeyAPI: api,
            dateProvider: TicketsDateProvider(date: now)
        )

        await viewModel.refreshOpenTickets(forceRemote: true)

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.tickets.map(\.id) == ["ticket_10", "ticket_11"])
        let cached = await ticketStore.loadOpenTickets()
        #expect(cached.map(\.id) == ["ticket_10", "ticket_11"])
    }

    @Test func recentScopeFiltersByUpdatedAtWindow() async {
        let now = Date(timeIntervalSince1970: 1_772_900_200)
        let ticketStore = TicketStore()
        let serviceState = TicketServiceStubState()
        let api = TicketsShopmonkeyStub(state: serviceState)

        await ticketStore.save(tickets: [
            makeTicket(id: "recent_1", number: "RO-3001", updatedAt: now.addingTimeInterval(-2 * 24 * 60 * 60)),
            makeTicket(id: "old_1", number: "RO-3002", updatedAt: now.addingTimeInterval(-50 * 24 * 60 * 60))
        ])

        let viewModel = TicketsViewModel(
            ticketStore: ticketStore,
            shopmonkeyAPI: api,
            dateProvider: TicketsDateProvider(date: now)
        )

        await viewModel.loadCachedState()
        viewModel.scope = .recent

        #expect(viewModel.filteredTickets.map(\.id) == ["recent_1"])
    }

    @Test func searchScopeFiltersLocallyByTicketFields() async {
        let now = Date(timeIntervalSince1970: 1_772_900_300)
        let ticketStore = TicketStore()
        let serviceState = TicketServiceStubState()
        let api = TicketsShopmonkeyStub(state: serviceState)

        await ticketStore.save(tickets: [
            makeTicket(id: "ticket_alpha", number: "RO-4100", updatedAt: now),
            TicketModel(
                id: "ticket_beta",
                number: "RO-4200",
                displayNumber: "RO-4200",
                status: "Open",
                customerName: "Jordan Driver",
                vehicleSummary: "2018 Accord",
                updatedAt: now.addingTimeInterval(-30),
                lineItems: []
            )
        ])

        let viewModel = TicketsViewModel(
            ticketStore: ticketStore,
            shopmonkeyAPI: api,
            dateProvider: TicketsDateProvider(date: now)
        )

        await viewModel.loadCachedState()
        viewModel.scope = .search
        viewModel.searchText = "jordan"

        #expect(viewModel.filteredTickets.map(\.id) == ["ticket_beta"])
    }
}
