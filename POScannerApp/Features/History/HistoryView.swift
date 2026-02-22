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
    let isTabActive: Bool
    @AppStorage("saveHistoryEnabled") private var saveHistoryEnabled: Bool = true
    @AppStorage("ignoreTaxAndTotals") private var ignoreTaxAndTotals: Bool = false
    @StateObject private var viewModel: HistoryViewModel
    @State private var hasLoaded: Bool = false
    @State private var retryErrorMessage: String?
    @State private var isRetryErrorPresented: Bool = false
    @State private var scope: HistoryScope = .all
    @State private var searchText: String = ""
    @State private var draftStoreRefreshTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL

    init(environment: AppEnvironment, isTabActive: Bool = true) {
        self.environment = environment
        self.isTabActive = isTabActive
        _viewModel = StateObject(
            wrappedValue: HistoryViewModel(
                dataController: environment.dataController,
                reviewDraftStore: environment.reviewDraftStore
            )
        )
    }

    var body: some View {
        Group {
            if !saveHistoryEnabled {
                ContentUnavailableView(
                    "History Disabled",
                    systemImage: "clock.badge.xmark",
                    description: Text("Enable \"Save History\" to keep local purchase-order records and draft intake snapshots.")
                )
            } else if viewModel.isLoading {
                ProgressView("Loading purchase order history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.orders.isEmpty && viewModel.inProgressDrafts.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock",
                    description: Text("Submitted purchase-order records and intake drafts will appear here.")
                )
            } else {
                List {
                    Section("Today's Parts Intake Snapshot") {
                        historyOverviewCard
                    }

                    Section("In-Progress Parts Intake Drafts") {
                        if viewModel.inProgressDrafts.isEmpty {
                            Text("No saved intake drafts.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.inProgressDrafts) { draft in
                                if draft.canResumeInReview {
                                    NavigationLink {
                                        ReviewView(
                                            environment: environment,
                                            parsedInvoice: draft.state.parsedInvoice.parsedInvoice,
                                            draftSnapshot: draft
                                        )
                                    } label: {
                                        draftRow(draft)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("Delete", role: .destructive) {
                                            AppHaptics.warning()
                                            Task { await viewModel.deleteDraft(draft) }
                                        }
                                    }
                                } else {
                                    Button {
                                        AppHaptics.selection()
                                        openURL(AppDeepLink.scanURL(draftID: draft.id))
                                    } label: {
                                        draftRow(draft)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("Delete", role: .destructive) {
                                            AppHaptics.warning()
                                            Task { await viewModel.deleteDraft(draft) }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        NativeSegmentedControl(
                            options: HistoryScope.allCases,
                            titleForOption: { $0.rawValue },
                            selection: $scope,
                            accessibilityIdentifier: "history.scopePicker"
                        )
                    }

                    Section("Submitted Purchase Orders") {
                        if filteredOrders.isEmpty {
                            Text("No purchase orders in this filter.")
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
                                    if row.statusBucket.allowsRetry {
                                        Button("Retry") {
                                            AppHaptics.impact(.medium, intensity: 0.8)
                                            Task { await retry(row) }
                                        }
                                        .tint(AppSurfaceStyle.warning)
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
                .searchable(text: $searchText, prompt: "Vendor, PO, status, or error")
            }
        }
        .navigationTitle("Purchase Order History")
        .navigationBarTitleDisplayMode(.large)
        .alert("Retry Failed", isPresented: $isRetryErrorPresented) {
            Button("OK") {}
        } message: {
            Text(retryErrorMessage ?? "Unexpected error")
        }
        .onAppear {
            if isTabActive && !hasLoaded {
                hasLoaded = true
                viewModel.loadHistory()
            }
        }
        .onChange(of: isTabActive) { _, active in
            guard active else { return }
            if !hasLoaded {
                hasLoaded = true
            }
            viewModel.loadHistory()
        }
        .onDisappear {
            draftStoreRefreshTask?.cancel()
            draftStoreRefreshTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDraftStoreDidChange)) { _ in
            guard isTabActive else { return }
            draftStoreRefreshTask?.cancel()
            draftStoreRefreshTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard !Task.isCancelled else { return }
                viewModel.loadHistory()
            }
        }
        .onChange(of: scope) { _, _ in
            AppHaptics.selection()
        }
        .animation(.snappy(duration: 0.22), value: viewModel.inProgressDrafts)
    }

    private func draftRow(_ draft: ReviewDraftSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(draft.displayVendorName)
                    .font(.headline)
                Spacer()
                Text(draft.workflowState.statusLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(draftBadgeColor(for: draft.workflowState))
                    .background(draftBadgeColor(for: draft.workflowState).opacity(0.15))
                    .clipShape(Capsule())
            }

            Text("\(draft.displaySecondaryLine) • Saved \(draft.updatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .animation(.snappy(duration: 0.22), value: draft.updatedAt)
    }

    private func draftBadgeColor(for state: ReviewDraftSnapshot.WorkflowState) -> Color {
        switch state {
        case .scanning, .ocrReview, .parsing, .submitting:
            return AppSurfaceStyle.info
        case .reviewReady, .reviewEdited:
            return AppSurfaceStyle.success
        case .failed:
            return AppSurfaceStyle.warning
        }
    }

    private var filteredOrders: [HistoryViewModel.HistoryRow] {
        let scoped: [HistoryViewModel.HistoryRow]
        switch scope {
        case .all:
            scoped = viewModel.orders
        case .attention:
            scoped = viewModel.orders.filter { row in
                row.statusBucket.countsAsAttention
            }
        case .submitted:
            scoped = viewModel.orders.filter { $0.statusBucket == .submitted }
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
            if row.status.localizedCaseInsensitiveContains(query) {
                return true
            }
            if let lastError = row.lastError, lastError.localizedCaseInsensitiveContains(query) {
                return true
            }
            return false
        }
    }

    private var todayOrders: [HistoryViewModel.HistoryRow] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return viewModel.orders.filter { $0.date >= startOfDay }
    }

    private var todayTrackedOrders: [HistoryViewModel.HistoryRow] {
        todayOrders.filter { $0.statusBucket.countsAsTrackedScan }
    }

    private var historyOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Draft Queue") {
                Text("\(draftQueueCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Ready for Review") {
                Text("\(reviewDraftCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Submitted Today") {
                Text("\(submittedCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Needs Attention") {
                Text("\(totalAttentionCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("PO Value Today") {
                Text(totalValueFormatted)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.headline)
        }
        .animation(.snappy(duration: 0.24), value: draftQueueCount)
        .animation(.snappy(duration: 0.24), value: reviewDraftCount)
        .animation(.snappy(duration: 0.24), value: submittedCount)
        .animation(.snappy(duration: 0.24), value: totalAttentionCount)
    }

    private var draftQueueCount: Int {
        viewModel.inProgressDrafts.count
    }

    private var reviewDraftCount: Int {
        viewModel.inProgressDrafts.filter {
            $0.workflowState == .reviewReady || $0.workflowState == .reviewEdited
        }.count
    }

    private var submittedCount: Int {
        todayTrackedOrders.filter { $0.statusBucket == .submitted }.count
    }

    private var pendingCount: Int {
        todayTrackedOrders.filter { $0.statusBucket == .pending }.count
    }

    private var failedCount: Int {
        todayTrackedOrders.filter { $0.statusBucket == .failed }.count
    }

    private var draftAttentionCount: Int {
        viewModel.inProgressDrafts.filter { $0.workflowState == .failed }.count
    }

    private var totalAttentionCount: Int {
        pendingCount + failedCount + draftAttentionCount
    }

    private var totalValueFormatted: String {
        let value = todayTrackedOrders.reduce(0.0) { $0 + $1.totalAmount }
        return value.formatted(.currency(code: "USD"))
    }

    private func historyRow(_ row: HistoryViewModel.HistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.vendorName)
                    .font(.body.weight(.semibold))
                Spacer()
                StatusBadge(status: row.status, bucket: row.statusBucket)
            }
            HStack(spacing: 8) {
                Text(row.formattedDate)
                if let poNumber = row.poNumber, !poNumber.isEmpty {
                    Text("PO #\(poNumber)")
                }
                Spacer()
                Text(row.formattedTotal)
                    .fontWeight(.semibold)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if row.statusBucket.allowsRetry,
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

        let submitter = POSubmissionService(
            shopmonkey: environment.shopmonkeyAPI,
            authorizeSubmission: { [environment] in
                try await environment.authenticateForSubmissionIfNeeded(forcePrompt: true)
            }
        )
        let result = await submitter.retry(purchaseOrder: purchaseOrder, ignoreTaxAndTotals: ignoreTaxAndTotals)
        if !result.succeeded {
            retryErrorMessage = result.message
            isRetryErrorPresented = true
            AppHaptics.error()
        } else {
            AppHaptics.success()
            viewModel.loadHistory()
        }
    }

}

private struct StatusBadge: View {
    let status: String
    let bucket: PurchaseOrderStatusBucket

    private var label: String {
        let normalized = PurchaseOrderStatusBucket.normalized(status)
        switch bucket {
        case .submitted:
            return "Submitted"
        case .pending:
            switch normalized {
            case "draft":
                return "Draft"
            case "submitting":
                return "Submitting"
            case "retry", "retrying":
                return "Retrying"
            case "ordered":
                return "Ordered"
            default:
                return normalized.isEmpty ? "Pending" : normalized.capitalized
            }
        case .failed:
            if normalized == "cancelled" || normalized == "canceled" {
                return "Cancelled"
            }
            return "Failed"
        case .ignored:
            return normalized.isEmpty ? "Unknown" : normalized.capitalized
        }
    }

    private var color: Color {
        switch bucket {
        case .submitted:
            return AppSurfaceStyle.success
        case .pending:
            return AppSurfaceStyle.info
        case .failed:
            return .red
        case .ignored:
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
