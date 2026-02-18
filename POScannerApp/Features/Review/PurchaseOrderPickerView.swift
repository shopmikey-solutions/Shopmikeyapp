//
//  PurchaseOrderPickerView.swift
//  POScannerApp
//

import SwiftUI

struct PurchaseOrderPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let service: any ShopmonkeyServicing
    let onSelect: (PurchaseOrderResponse) -> Void

    @State private var purchaseOrders: [PurchaseOrderResponse] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var searchText: String = ""

    private var filteredPurchaseOrders: [PurchaseOrderResponse] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return purchaseOrders }

        return purchaseOrders.filter { purchaseOrder in
            if purchaseOrder.id.localizedCaseInsensitiveContains(query) { return true }
            if let number = purchaseOrder.number, number.localizedCaseInsensitiveContains(query) { return true }
            if let vendorName = purchaseOrder.vendorName, vendorName.localizedCaseInsensitiveContains(query) { return true }
            return purchaseOrder.status.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if isLoading && purchaseOrders.isEmpty {
                ProgressView("Loading Shopmonkey purchase orders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, purchaseOrders.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Couldn't Load Shopmonkey Purchase Orders",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )

                    Button("Retry") {
                        Task { await fetchPurchaseOrders() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if filteredPurchaseOrders.isEmpty {
                ContentUnavailableView(
                    "No Purchase Orders Found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(searchText.isEmpty ? "No purchase orders were returned from Shopmonkey." : "No purchase orders match your search.")
                )
            } else {
                List {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }

                    ForEach(filteredPurchaseOrders) { purchaseOrder in
                        Button {
                            onSelect(purchaseOrder)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(purchaseOrder.number ?? purchaseOrder.id)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    statusBadge(for: purchaseOrder.status, isDraft: purchaseOrder.isDraft)
                                }

                                if let vendorName = purchaseOrder.vendorName, !vendorName.isEmpty {
                                    Text(vendorName)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                if purchaseOrder.number == nil {
                                    Text(purchaseOrder.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
                .nativeListSurface()
                .refreshable {
                    await fetchPurchaseOrders()
                }
            }
        }
        .navigationTitle("Select Shopmonkey Purchase Order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $searchText, prompt: "PO number, vendor, or status")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .task {
            await fetchPurchaseOrders()
        }
    }

    private func fetchPurchaseOrders() async {
        if isLoading { return }

        isLoading = true
        errorMessage = nil

        do {
            purchaseOrders = try await service.getPurchaseOrders()
        } catch {
            errorMessage = userMessage(for: error)
        }

        isLoading = false
    }

    private func statusBadge(for status: String, isDraft: Bool) -> some View {
        Text(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : status)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isDraft ? .green : .orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isDraft ? Color.green : Color.orange).opacity(0.16))
            .clipShape(Capsule())
    }
}

#if DEBUG
#Preview("Purchase Order Picker") {
    PurchaseOrderPickerView(service: PreviewFixtures.previewShopmonkeyService) { _ in }
}
#endif
