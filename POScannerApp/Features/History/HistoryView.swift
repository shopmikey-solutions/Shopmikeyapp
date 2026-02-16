//
//  HistoryView.swift
//  POScannerApp
//

import CoreData
import SwiftUI

struct HistoryView: View {
    private enum HistoryScope: String, CaseIterable, Identifiable {
        case all = "All"
        case attention = "Needs Attention"
        case submitted = "Submitted"

        var id: String { rawValue }
    }

    let environment: AppEnvironment
    @AppStorage("saveHistoryEnabled") private var saveHistoryEnabled: Bool = true
    @AppStorage("ignoreTaxAndTotals") private var ignoreTaxAndTotals: Bool = false
    @StateObject private var viewModel: HistoryViewModel
    @State private var hasLoaded: Bool = false
    @State private var retryErrorMessage: String?
    @State private var isRetryErrorPresented: Bool = false
    @State private var scope: HistoryScope = .all

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(wrappedValue: HistoryViewModel(dataController: environment.dataController))
    }

    var body: some View {
        ZStack {
            backgroundLayer

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
                        Section {
                            historyOverviewCard

                            Picker("Scope", selection: $scope) {
                                ForEach(HistoryScope.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("history.scopePicker")
                        }

                        Section {
                            if filteredOrders.isEmpty {
                                Text("No orders in this scope.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(filteredOrders) { row in
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
                                        historyRow(row)
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
                        } header: {
                            Text("Orders")
                                .appSectionHeaderStyle()
                        }
                    }
                    .appFormChrome()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 84)
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
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

    private var backgroundLayer: some View {
        AppScreenBackground()
    }

    private var filteredOrders: [HistoryViewModel.HistoryRow] {
        switch scope {
        case .all:
            return viewModel.orders
        case .attention:
            return viewModel.orders.filter { row in
                let normalized = row.status.lowercased()
                return normalized == "failed" || normalized == "submitting"
            }
        case .submitted:
            return viewModel.orders.filter { $0.status.lowercased() == "submitted" }
        }
    }

    private var historyOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History Snapshot")
                .font(AppSurfaceStyle.cardTitleFont)

            HStack(spacing: 8) {
                summaryChip(title: "\(viewModel.orders.count) total", color: .blue)
                summaryChip(title: "\(submittedCount) submitted", color: .green)
                summaryChip(title: "\(pendingCount) pending", color: .orange)
                if failedCount > 0 {
                    summaryChip(title: "\(failedCount) failed", color: .red)
                }
            }

            HStack {
                Text("Captured Value")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(totalValueFormatted)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private var submittedCount: Int {
        viewModel.orders.filter { $0.status.lowercased() == "submitted" }.count
    }

    private var pendingCount: Int {
        viewModel.orders.filter { $0.status.lowercased() == "submitting" }.count
    }

    private var failedCount: Int {
        viewModel.orders.filter { $0.status.lowercased() == "failed" }.count
    }

    private var totalValueFormatted: String {
        let value = filteredOrders.reduce(0.0) { $0 + $1.totalAmount }
        return value.formatted(.currency(code: "USD"))
    }

    private func historyRow(_ row: HistoryViewModel.HistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.vendorName)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
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
                    .fontWeight(.semibold)
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

    private func summaryChip(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
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
