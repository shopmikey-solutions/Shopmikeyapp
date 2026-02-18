//
//  OrderPickerView.swift
//  POScannerApp
//

import SwiftUI

struct OrderPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let service: any ShopmonkeyServicing
    let onSelect: (OrderSummary) -> Void

    @State private var orders: [OrderSummary] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var searchText: String = ""

    private var filteredOrders: [OrderSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return orders }

        return orders.filter { order in
            if order.displayTitle.localizedCaseInsensitiveContains(query) { return true }
            if let orderName = order.orderName, orderName.localizedCaseInsensitiveContains(query) { return true }
            if let customer = order.customerName, customer.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    var body: some View {
        Group {
            if isLoading && orders.isEmpty {
                ProgressView("Loading Shopmonkey orders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, orders.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Couldn't Load Shopmonkey Orders",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )

                    Button("Retry") {
                        Task { await fetchOrders() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if filteredOrders.isEmpty {
                ContentUnavailableView(
                    "No Orders Found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(searchText.isEmpty ? "No orders were returned from Shopmonkey." : "No orders match your search.")
                )
            } else {
                List {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }

                    ForEach(filteredOrders) { order in
                        Button {
                            onSelect(order)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(order.orderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                     ? (order.orderName ?? "")
                                     : order.displayTitle)
                                    .font(.headline)

                                if let number = order.number?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !number.isEmpty {
                                    Text("Order #\(number)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                if let customer = order.customerName, !customer.isEmpty {
                                    Text(customer)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .nativeListSurface()
                .refreshable {
                    await fetchOrders()
                }
            }
        }
        .navigationTitle("Select Shopmonkey Order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $searchText)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .task {
            await fetchOrders()
        }
    }

    private func fetchOrders() async {
        if isLoading { return }

        isLoading = true
        errorMessage = nil

        do {
            orders = try await service.fetchOrders()
        } catch {
            errorMessage = userMessage(for: error)
        }

        isLoading = false
    }
}

#if DEBUG
#Preview("Order Picker") {
    OrderPickerView(service: PreviewFixtures.previewShopmonkeyService) { _ in }
}
#endif
