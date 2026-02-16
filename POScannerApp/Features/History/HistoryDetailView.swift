//
//  HistoryDetailView.swift
//  POScannerApp
//

import SwiftUI

struct HistoryDetailView: View {
    let purchaseOrder: PurchaseOrder

    var body: some View {
        List {
            Section {
                summaryCard
            }

            Section {
                LabeledContent("Vendor", value: purchaseOrder.vendorName)
                if let poNumber = purchaseOrder.poNumber, !poNumber.isEmpty {
                    LabeledContent("PO Number", value: poNumber)
                }
                if let orderId = purchaseOrder.orderId, !orderId.isEmpty {
                    LabeledContent("Order ID", value: orderId)
                }
                if let serviceId = purchaseOrder.serviceId, !serviceId.isEmpty {
                    LabeledContent("Service ID", value: serviceId)
                }
                LabeledContent("Date", value: purchaseOrder.date.formatted(date: .abbreviated, time: .shortened))
                if let submittedAt = purchaseOrder.submittedAt {
                    LabeledContent("Submitted", value: submittedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Status", value: purchaseOrder.status)
                LabeledContent("Total", value: purchaseOrder.totalAmount.formatted(.currency(code: "USD")))
            } header: {
                Text("Purchase Order")
                    .appSectionHeaderStyle()
            }

            if let lastError = purchaseOrder.lastError, !lastError.isEmpty {
                Section {
                    Text(lastError)
                        .foregroundStyle(.red)
                } header: {
                    Text("Last Error")
                        .appSectionHeaderStyle()
                }
            }

            Section {
                if purchaseOrder.itemsSorted.isEmpty {
                    Text("No items saved.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(purchaseOrder.itemsSorted) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name)
                                .font(.headline)
                            HStack {
                                Text("Qty \(item.quantity)")
                                Spacer()
                                Text(item.cost, format: .number.precision(.fractionLength(2)))
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Items")
                    .appSectionHeaderStyle()
            }
        }
        .appFormChrome()
        .background(backgroundLayer)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 84)
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var backgroundLayer: some View {
        AppScreenBackground()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Submission Snapshot")
                .font(AppSurfaceStyle.cardTitleFont)
            HStack(spacing: 8) {
                statusChip(title: purchaseOrder.status)
                Text(purchaseOrder.totalAmount.formatted(.currency(code: "USD")))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            Text(purchaseOrder.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func statusChip(title: String) -> some View {
        let color: Color
        switch title.lowercased() {
        case "submitted":
            color = .green
        case "failed":
            color = .red
        case "submitting":
            color = .orange
        default:
            color = .gray
        }
        return Text(title.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
