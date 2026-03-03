//
//  PurchaseOrdersView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import SwiftUI

struct PurchaseOrdersView: View {
    private static let pageSize = PurchaseOrderStore.defaultPageSize
    private static let stalenessThreshold: TimeInterval = 10 * 60

    let environment: AppEnvironment

    @State private var purchaseOrders: [PurchaseOrderSummary] = []
    @State private var currentPage = 0
    @State private var hasMorePages = false
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var stalePromptDismissed = false
    @State private var isStale = false

    var body: some View {
        ZStack {
            List {
                if isStale && !stalePromptDismissed {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Purchase order data may be stale.")
                            .font(.subheadline.weight(.semibold))
                        Text("Refresh before using this data for receive actions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Refresh") {
                                Task { await refreshFromAPI() }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("purchaseOrders.staleRefreshButton")

                            Button("Cancel") {
                                stalePromptDismissed = true
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("purchaseOrders.staleCancelButton")
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("purchaseOrders.stalePrompt")
                }

                if purchaseOrders.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No open purchase orders")
                            .font(.subheadline.weight(.semibold))
                        Text("Pull or refresh to update your local purchase order cache.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("purchaseOrders.emptyState")
                } else {
                    ForEach(purchaseOrders) { purchaseOrder in
                        NavigationLink {
                            PurchaseOrderDetailView(
                                environment: environment,
                                purchaseOrderID: purchaseOrder.id
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(purchaseOrder.vendorName ?? "Unknown Vendor")
                                        .font(.headline)
                                    Spacer()
                                    Text(purchaseOrder.status ?? "Unknown")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    if let totalLineCount = purchaseOrder.totalLineCount {
                                        Text("Lines: \(totalLineCount)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let updatedAt = purchaseOrder.updatedAt ?? purchaseOrder.createdAt {
                                        Spacer()
                                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("purchaseOrders.row.\(purchaseOrder.id)")
                    }

                    if hasMorePages {
                        Button("Load More") {
                            Task { await loadNextPage() }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("purchaseOrders.loadMore")
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("purchaseOrders.errorMessage")
                }
            }

            if isRefreshing, purchaseOrders.isEmpty {
                CenteredLoadingView(label: "Loading purchase orders…")
                    .accessibilityIdentifier("purchaseOrders.loading")
            }
        }
        .navigationTitle("Purchase Orders")
        .accessibilityIdentifier("purchaseOrders.list")
        .animation(.easeInOut(duration: 0.2), value: purchaseOrders)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isRefreshing ? "Refreshing…" : "Refresh") {
                    Task { await refreshFromAPI() }
                }
                .disabled(isRefreshing)
                .accessibilityIdentifier("purchaseOrders.refreshButton")
            }
        }
        .refreshable {
            await refreshFromAPI()
        }
        .task {
            await loadFromStore()
            await refreshFromAPI()
        }
    }

    @MainActor
    private func loadFromStore() async {
        currentPage = 0
        purchaseOrders = await environment.purchaseOrderStore.loadOpenPurchaseOrdersPage(
            page: currentPage,
            pageSize: Self.pageSize
        )
        let total = await environment.purchaseOrderStore.openPurchaseOrderCount()
        hasMorePages = purchaseOrders.count < total
        isStale = await environment.purchaseOrderStore.isStale(
            now: Date(),
            threshold: Self.stalenessThreshold
        )
        stalePromptDismissed = !isStale
    }

    @MainActor
    private func loadNextPage() async {
        guard hasMorePages else { return }
        let nextPage = currentPage + 1
        let nextBatch = await environment.purchaseOrderStore.loadOpenPurchaseOrdersPage(
            page: nextPage,
            pageSize: Self.pageSize
        )
        guard !nextBatch.isEmpty else {
            hasMorePages = false
            return
        }
        purchaseOrders.append(contentsOf: nextBatch)
        currentPage = nextPage
        let total = await environment.purchaseOrderStore.openPurchaseOrderCount()
        hasMorePages = purchaseOrders.count < total
    }

    @MainActor
    private func refreshFromAPI() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await environment.shopmonkeyAPI.fetchOpenPurchaseOrders()
            await environment.purchaseOrderStore.saveOpenPurchaseOrders(fetched)
            currentPage = 0
            purchaseOrders = await environment.purchaseOrderStore.loadOpenPurchaseOrdersPage(
                page: currentPage,
                pageSize: Self.pageSize
            )
            let total = await environment.purchaseOrderStore.openPurchaseOrderCount()
            hasMorePages = purchaseOrders.count < total
            isStale = await environment.purchaseOrderStore.isStale(
                now: Date(),
                threshold: Self.stalenessThreshold
            )
            stalePromptDismissed = !isStale
            errorMessage = nil
        } catch {
            guard !isRequestCancellation(error) else { return }
            errorMessage = "Could not refresh purchase orders."
        }
    }
}
