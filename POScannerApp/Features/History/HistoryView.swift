//
//  HistoryView.swift
//  POScannerApp
//

import CoreData
import SwiftUI

struct HistoryView: View {
    let environment: AppEnvironment
    @AppStorage("saveHistoryEnabled") private var saveHistoryEnabled: Bool = true
    @AppStorage("ignoreTaxAndTotals") private var ignoreTaxAndTotals: Bool = false
    @StateObject private var viewModel: HistoryViewModel
    @State private var hasLoaded: Bool = false
    @State private var retryErrorMessage: String?
    @State private var isRetryErrorPresented: Bool = false

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(wrappedValue: HistoryViewModel(dataController: environment.dataController))
    }

    var body: some View {
        Group {
            if !saveHistoryEnabled {
                ContentUnavailableView(
                    "History Disabled",
                    systemImage: "clock.badge.xmark",
                    description: Text("Enable “Save History” in Settings to keep scanned purchase orders locally.")
                )
            } else if viewModel.isLoading {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.orders.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock",
                    description: Text("Scanned purchase orders you save will appear here.")
                )
            } else {
                List {
                    ForEach(viewModel.orders) { row in
                        NavigationLink {
                            if let purchaseOrder = viewModel.purchaseOrder(for: row) {
                                HistoryDetailView(purchaseOrder: purchaseOrder)
                            } else {
                                ContentUnavailableView(
                                    "Unavailable",
                                    systemImage: "exclamationmark.triangle",
                                    description: Text("This history item could not be loaded.")
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.vendorName)
                                        .font(.headline)
                                    Spacer()
                                    StatusBadge(status: row.status)
                                }
                                HStack(spacing: 8) {
                                    Text(row.formattedDate)
                                    if let poNumber = row.poNumber, !poNumber.isEmpty {
                                        Text("PO \(poNumber)")
                                    }
                                    Spacer()
                                    Text(row.formattedTotal)
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                                if row.status.lowercased() == "failed",
                                   let lastError = row.lastError,
                                   !lastError.isEmpty {
                                    Text(lastError)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if row.status.lowercased() == "failed" {
                                Button("Retry") {
                                    Task { await retry(row) }
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .alert("Retry Failed", isPresented: $isRetryErrorPresented) {
            Button("OK") {}
        } message: {
            Text(retryErrorMessage ?? "Unexpected error")
        }
        .onAppear {
            if !hasLoaded {
                hasLoaded = true
                viewModel.loadHistory()
            }
        }
    }

    @MainActor
    private func retry(_ row: HistoryViewModel.HistoryRow) async {
        guard let purchaseOrder = viewModel.purchaseOrder(for: row) else {
            retryErrorMessage = "Unable to load this order for retry."
            isRetryErrorPresented = true
            return
        }

        let submitter = POSubmissionService(shopmonkey: environment.shopmonkeyAPI)
        let result = await submitter.retry(purchaseOrder: purchaseOrder, ignoreTaxAndTotals: ignoreTaxAndTotals)
        if !result.succeeded {
            retryErrorMessage = result.message
            isRetryErrorPresented = true
        } else {
            viewModel.loadHistory()
        }
    }
}

private struct StatusBadge: View {
    let status: String

    private var label: String {
        switch status.lowercased() {
        case "draft":
            return "Draft"
        case "submitting":
            return "Submitting"
        case "submitted":
            return "Submitted"
        case "failed":
            return "Failed"
        default:
            return status.isEmpty ? "Unknown" : status.capitalized
        }
    }

    private var color: Color {
        switch status.lowercased() {
        case "draft":
            return .gray
        case "submitting":
            return .blue
        case "submitted":
            return .green
        case "failed":
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
