//
//  TicketsView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import SwiftUI

struct TicketsView: View {
    let environment: AppEnvironment

    @StateObject private var viewModel: TicketsViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(
            wrappedValue: TicketsViewModel(
                ticketStore: environment.ticketStore,
                shopmonkeyAPI: environment.shopmonkeyAPI,
                dateProvider: environment.dateProvider
            )
        )
    }

    var body: some View {
        List {
            controlsSection

            if let lastUpdated = viewModel.lastUpdated {
                Section {
                    Text("Updated \(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("tickets.lastUpdated")
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("tickets.error")
                }
            }

            contentSection
        }
        .navigationTitle("Tickets")
        .accessibilityIdentifier("tickets.list")
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search ticket number, customer, vehicle"
        )
        .refreshable {
            await viewModel.refreshForCurrentScope(forceRemote: true)
        }
        .task {
            await viewModel.loadCachedState()
        }
    }

    private var controlsSection: some View {
        Section {
            Picker("Scope", selection: $viewModel.scope) {
                ForEach(TicketsViewModel.Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("tickets.scopePicker")

            if viewModel.scope == .search && viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Enter search text to narrow cached tickets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tickets.searchHint")
            }

            if viewModel.activeTicketID != nil {
                Button("Clear Active Ticket") {
                    Task {
                        await viewModel.clearActiveTicketContext()
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("tickets.clearActiveTicket")
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        Section {
            if viewModel.isLoading && viewModel.filteredTickets.isEmpty {
                ProgressView("Loading tickets…")
                    .accessibilityIdentifier("tickets.loading")
            } else if viewModel.filteredTickets.isEmpty {
                Text(emptyStateMessage)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tickets.empty")
            } else {
                ForEach(viewModel.filteredTickets) { ticket in
                    NavigationLink {
                        TicketDetailView(environment: environment, ticketID: ticket.id)
                    } label: {
                        ticketRow(ticket)
                    }
                    .accessibilityIdentifier("tickets.row.\(ticket.id)")
                }
            }
        }
    }

    private func ticketRow(_ ticket: TicketModel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.displayNumber ?? ticket.number ?? ticket.id)
                    .font(.headline)
                if let customerName = ticket.customerName, !customerName.isEmpty {
                    Text(customerName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let vehicleSummary = ticket.vehicleSummary, !vehicleSummary.isEmpty {
                    Text(vehicleSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if let status = ticket.status, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.activeTicketID == ticket.id {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var emptyStateMessage: String {
        switch viewModel.scope {
        case .open:
            return "No open tickets in cache. Pull to refresh."
        case .recent:
            return "No recently updated tickets in cache."
        case .search:
            return "No tickets matched your search."
        }
    }
}
