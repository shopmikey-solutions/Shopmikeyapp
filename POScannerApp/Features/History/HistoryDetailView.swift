//
//  HistoryDetailView.swift
//  POScannerApp
//

import SwiftUI

struct HistoryDetailView: View {
    let purchaseOrder: PurchaseOrder

    var body: some View {
        List {
            Section("Submission Snapshot") {
                HStack(spacing: 8) {
                    statusChip(title: purchaseOrder.status)
                    Text(purchaseOrder.totalAmount.formatted(.currency(code: "USD")))
                        .font(.headline)
                }
                Text(purchaseOrder.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Purchase Order Record") {
                LabeledContent("Supplier", value: purchaseOrder.vendorName)
                if let poNumber = purchaseOrder.poNumber, !poNumber.isEmpty {
                    LabeledContent("PO Number", value: poNumber)
                }
                if let orderId = purchaseOrder.orderId, !orderId.isEmpty {
                    LabeledContent("Shopmonkey Order ID", value: orderId)
                }
                if let serviceId = purchaseOrder.serviceId, !serviceId.isEmpty {
                    LabeledContent("Shopmonkey Service ID", value: serviceId)
                }
                LabeledContent("Date", value: purchaseOrder.date.formatted(date: .abbreviated, time: .shortened))
                if let submittedAt = purchaseOrder.submittedAt {
                    LabeledContent("Submitted", value: submittedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Status", value: purchaseOrder.status)
                LabeledContent("Total", value: purchaseOrder.totalAmount.formatted(.currency(code: "USD")))
            }

            if let lastError = purchaseOrder.lastError, !lastError.isEmpty {
                Section("Last Error") {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }

            Section("Items") {
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
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("PO Details")
        .navigationBarTitleDisplayMode(.inline)
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
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

#if DEBUG
private struct HistoryDetailPreviewContainer: View {
    private let environment: AppEnvironment
    private let purchaseOrder: PurchaseOrder

    init() {
        let environment = PreviewFixtures.makeEnvironment(seedHistory: true)
        self.environment = environment
        self.purchaseOrder = PreviewFixtures.firstHistoryOrder(in: environment.dataController.viewContext)
    }

    var body: some View {
        NavigationStack {
            HistoryDetailView(purchaseOrder: purchaseOrder)
        }
    }
}

#Preview("History Detail") {
    HistoryDetailPreviewContainer()
}
#endif
