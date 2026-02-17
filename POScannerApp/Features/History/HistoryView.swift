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
    @State private var searchText: String = ""

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
                    Section("Today Snapshot") {
                        historyOverviewCard
                    }

                    Section {
                        NativeSegmentedControl(
                            options: HistoryScope.allCases,
                            titleForOption: { $0.rawValue },
                            selection: $scope,
                            accessibilityIdentifier: "history.scopePicker"
                        )
                    }

                    Section("Orders") {
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
                                .contextMenu {
                                    Button("Filter by Vendor") {
                                        searchText = row.vendorName
                                    }
                                    if let poNumber = row.poNumber, !poNumber.isEmpty {
                                        Button("Filter by PO \(poNumber)") {
                                            searchText = poNumber
                                        }
                                    }
                                    if row.status.lowercased() == "failed" {
                                        Button("Retry Submission") {
                                            Task { await retry(row) }
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
                .listStyle(.insetGrouped)
                .nativeListSurface()
                .refreshable {
                    viewModel.loadHistory()
                }
                .searchable(text: $searchText, prompt: "Vendor or PO")
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
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

    private var filteredOrders: [HistoryViewModel.HistoryRow] {
        let scoped: [HistoryViewModel.HistoryRow]
        switch scope {
        case .all:
            scoped = viewModel.orders
        case .attention:
            scoped = viewModel.orders.filter { row in
                let normalized = row.status.lowercased()
                return normalized == "failed" || normalized == "submitting"
            }
        case .submitted:
            scoped = viewModel.orders.filter { $0.status.lowercased() == "submitted" }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scoped }

        return scoped.filter { row in
            if row.vendorName.localizedCaseInsensitiveContains(query) {
                return true
            }
            if let poNumber = row.poNumber, poNumber.localizedCaseInsensitiveContains(query) {
                return true
            }
            return false
        }
    }

    private var todayOrders: [HistoryViewModel.HistoryRow] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return viewModel.orders.filter { $0.date >= startOfDay }
    }

    private var historyOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Scans Today", value: "\(todayOrders.count)")
            LabeledContent("Submitted", value: "\(submittedCount)")
            LabeledContent("Needs Attention", value: "\(pendingCount + failedCount)")
            LabeledContent("Captured Value Today", value: totalValueFormatted)
                .font(.headline)
        }
    }

    private var submittedCount: Int {
        todayOrders.filter { $0.status.lowercased() == "submitted" }.count
    }

    private var pendingCount: Int {
        todayOrders.filter { $0.status.lowercased() == "submitting" }.count
    }

    private var failedCount: Int {
        todayOrders.filter { $0.status.lowercased() == "failed" }.count
    }

    private var totalValueFormatted: String {
        let value = todayOrders.reduce(0.0) { $0 + $1.totalAmount }
        return value.formatted(.currency(code: "USD"))
    }

    private func historyRow(_ row: HistoryViewModel.HistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.vendorName)
                    .font(.body.weight(.semibold))
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
            .font(.footnote)
            .foregroundStyle(.secondary)

            if row.status.lowercased() == "failed",
               let lastError = row.lastError,
               !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}

#if DEBUG
#Preview("History") {
    NavigationStack {
        HistoryView(environment: PreviewFixtures.makeEnvironment(seedHistory: true))
    }
}
#endif
