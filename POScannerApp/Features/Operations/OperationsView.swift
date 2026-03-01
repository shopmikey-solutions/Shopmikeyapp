//
//  OperationsView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import SwiftUI

struct OperationsView: View {
    let environment: AppEnvironment

    @StateObject private var viewModel: OperationsViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(
            wrappedValue: OperationsViewModel(
                inventoryStore: environment.inventoryStore,
                purchaseOrderStore: environment.purchaseOrderStore,
                ticketStore: environment.ticketStore,
                syncOperationQueue: environment.syncOperationQueue
            )
        )
    }

    var body: some View {
        List {
            summarySection
            quickNavigationSection
            lowStockSection
        }
        .navigationTitle("Operations")
        .accessibilityIdentifier("operations.list")
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.refresh()
        }
    }

    private var summarySection: some View {
        Section("Overview") {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                OperationsMetricCard(
                    title: "Low Stock",
                    value: "\(viewModel.lowStockItems.count)",
                    detail: "Qty on hand ≤ 1",
                    tint: .orange
                )
                .accessibilityIdentifier("operations.metric.lowStock")

                OperationsMetricCard(
                    title: "Open POs",
                    value: "\(viewModel.openPurchaseOrderCount)",
                    detail: "Read-only cache",
                    tint: .blue
                )
                .accessibilityIdentifier("operations.metric.openPOs")

                OperationsMetricCard(
                    title: "Open Tickets",
                    value: "\(viewModel.openTicketCount)",
                    detail: "Read-only cache",
                    tint: .green
                )
                .accessibilityIdentifier("operations.metric.openTickets")

                OperationsMetricCard(
                    title: "Sync Queue",
                    value: "\(viewModel.pendingSyncCount)",
                    detail: "Failed: \(viewModel.failedSyncCount)",
                    tint: viewModel.failedSyncCount > 0 ? .red : .indigo
                )
                .accessibilityIdentifier("operations.metric.syncQueue")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if let lastRefreshedAt = viewModel.lastRefreshedAt {
                Text("Updated \(lastRefreshedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("operations.lastRefreshed")
            }
        }
    }

    private var quickNavigationSection: some View {
        Section("Quick Navigation") {
            NavigationLink {
                InventoryView(environment: environment)
            } label: {
                Label("Go to Inventory", systemImage: "shippingbox")
            }
            .accessibilityIdentifier("operations.nav.inventory")

            NavigationLink {
                PurchaseOrdersView(environment: environment)
            } label: {
                Label("Go to Purchase Orders", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("operations.nav.purchaseOrders")

            NavigationLink {
                OperationsTicketsView(environment: environment)
            } label: {
                Label("Go to Tickets", systemImage: "wrench.and.screwdriver")
            }
            .accessibilityIdentifier("operations.nav.tickets")

            NavigationLink {
                SettingsView(environment: environment)
            } label: {
                Label("Go to Sync Health", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("operations.nav.syncHealth")
        }
    }

    private var lowStockSection: some View {
        Section("Low Stock Items") {
            if viewModel.isLoading && viewModel.lowStockItems.isEmpty {
                ProgressView("Loading operations data…")
                    .accessibilityIdentifier("operations.loading")
            } else if viewModel.lowStockItems.isEmpty {
                OperationsEmptyStateRow(
                    icon: "shippingbox",
                    title: "No low-stock items",
                    detail: "Pull inventory in the Inventory tab to populate this list."
                )
                .accessibilityIdentifier("operations.lowStock.empty")
            } else {
                ForEach(viewModel.lowStockItems) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayPartNumber)
                                .font(.subheadline.weight(.semibold))
                            Text(item.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Text(item.normalizedQuantityOnHand.formatted(.number.precision(.fractionLength(0...2))))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(item.normalizedQuantityOnHand <= 0 ? .red : .orange)
                    }
                    .accessibilityIdentifier("operations.lowStock.item.\(item.id)")
                }
            }
        }
    }
}

private struct OperationsTicketsView: View {
    let environment: AppEnvironment

    @State private var isLoading: Bool = true
    @State private var openTickets: [TicketModel] = []
    @State private var activeTicketID: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading open tickets…")
                    .accessibilityIdentifier("operations.tickets.loading")
            } else if openTickets.isEmpty {
                OperationsEmptyStateRow(
                    icon: "wrench.and.screwdriver",
                    title: "No open tickets",
                    detail: "Open tickets appear here after loading ticket cache."
                )
                .accessibilityIdentifier("operations.tickets.empty")
            } else {
                ForEach(openTickets) { ticket in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ticket.displayNumber ?? ticket.number ?? ticket.id)
                                .font(.subheadline.weight(.semibold))
                            if let customerName = ticket.customerName, !customerName.isEmpty {
                                Text(customerName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if activeTicketID == ticket.id {
                            Text("Active")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    .accessibilityIdentifier("operations.tickets.item.\(ticket.id)")
                }
            }
        }
        .navigationTitle("Open Tickets")
        .accessibilityIdentifier("operations.tickets.list")
        .refreshable {
            await reload()
        }
        .task {
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        activeTicketID = await environment.ticketStore.activeTicketID()
        openTickets = await environment.ticketStore.loadOpenTickets()
    }
}
