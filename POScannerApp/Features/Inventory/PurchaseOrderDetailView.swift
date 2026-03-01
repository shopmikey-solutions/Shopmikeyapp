//
//  PurchaseOrderDetailView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import SwiftUI

struct PurchaseOrderDetailView: View {
    let environment: AppEnvironment
    let purchaseOrderID: String

    @State private var detail: PurchaseOrderDetail?
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let detail {
                Section("Summary") {
                    detailRow(label: "Vendor", value: detail.vendorName ?? "Unknown Vendor")
                    detailRow(label: "Status", value: detail.status ?? "Unknown")
                    if isRefreshing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing details…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("purchaseOrder.detail.refreshing")
                    }
                    if let updatedAt = detail.updatedAt ?? detail.createdAt {
                        detailRow(
                            label: "Updated",
                            value: updatedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    NavigationLink {
                        ReceiveItemView(
                            environment: environment,
                            purchaseOrderID: purchaseOrderID
                        )
                    } label: {
                        Label("Receive Items", systemImage: "barcode.viewfinder")
                    }
                    .accessibilityIdentifier("purchaseOrder.detail.receiveItemsLink")
                }

                Section("Line Items") {
                    if detail.lineItems.isEmpty {
                        Text("No line items available.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("purchaseOrder.detail.emptyLineItems")
                    } else {
                        ForEach(detail.lineItems) { lineItem in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(lineItem.description)
                                    .font(.headline)

                                HStack {
                                    Text("Ordered: \(decimalString(lineItem.quantityOrdered))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let quantityReceived = lineItem.quantityReceived {
                                        Text("Received: \(decimalString(quantityReceived))")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if let partNumber = normalizedOptionalString(lineItem.partNumber) {
                                    Text("PN: \(partNumber)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if isRefreshing {
                Section {
                    ProgressView("Loading purchase order...")
                        .accessibilityIdentifier("purchaseOrder.detail.loading")
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Purchase order details unavailable")
                            .font(.subheadline.weight(.semibold))
                        Text("Refresh to load cached detail for this purchase order.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("purchaseOrder.detail.empty")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("purchaseOrder.detail.errorMessage")
                }
            }
        }
        .navigationTitle("PO Detail")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("purchaseOrder.detail.list")
        .animation(.easeInOut(duration: 0.2), value: detail?.lineItems.count ?? 0)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isRefreshing ? "Refreshing…" : "Refresh") {
                    Task { await refreshDetail() }
                }
                .disabled(isRefreshing)
                .accessibilityIdentifier("purchaseOrder.detail.refreshButton")
            }
        }
        .refreshable {
            await refreshDetail()
        }
        .task {
            await loadCachedDetail()
            if detail == nil {
                await refreshDetail()
            }
        }
    }

    @MainActor
    private func loadCachedDetail() async {
        detail = await environment.purchaseOrderStore.loadPurchaseOrderDetail(id: purchaseOrderID)
    }

    @MainActor
    private func refreshDetail() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetchedDetail = try await environment.shopmonkeyAPI.fetchPurchaseOrder(id: purchaseOrderID)
            await environment.purchaseOrderStore.savePurchaseOrderDetail(fetchedDetail)
            detail = await environment.purchaseOrderStore.loadPurchaseOrderDetail(id: purchaseOrderID)
            errorMessage = nil
        } catch {
            errorMessage = "Could not refresh purchase order details."
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
