//
//  PurchaseOrdersView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import SwiftUI

struct PurchaseOrdersView: View {
    let environment: AppEnvironment

    @State private var purchaseOrders: [PurchaseOrderSummary] = []
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isRefreshing, purchaseOrders.isEmpty {
                ProgressView("Loading purchase orders…")
                    .accessibilityIdentifier("purchaseOrders.loading")
            } else if purchaseOrders.isEmpty {
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
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("purchaseOrders.errorMessage")
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
        purchaseOrders = await environment.purchaseOrderStore.loadOpenPurchaseOrders()
    }

    @MainActor
    private func refreshFromAPI() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await environment.shopmonkeyAPI.fetchOpenPurchaseOrders()
            await environment.purchaseOrderStore.saveOpenPurchaseOrders(fetched)
            purchaseOrders = await environment.purchaseOrderStore.loadOpenPurchaseOrders()
            errorMessage = nil
        } catch {
            errorMessage = "Could not refresh purchase orders."
        }
    }
}
