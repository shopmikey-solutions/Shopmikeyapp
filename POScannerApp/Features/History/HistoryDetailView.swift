//
//  HistoryDetailView.swift
//  POScannerApp
//

import SwiftUI

struct HistoryDetailView: View {
    let purchaseOrder: PurchaseOrder

    var body: some View {
        List {
            Section("Purchase Order") {
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
                LabeledContent("Total", value: purchaseOrder.totalAmount.formatted(.number.precision(.fractionLength(2))))
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
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
