//
//  ReviewView.swift
//  POScannerApp
//

import SwiftUI

struct ReviewView: View {
    @StateObject var viewModel: ReviewViewModel
    @State private var focusNeedsReviewOnly: Bool = false
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, parsedInvoice: ParsedInvoice) {
        _viewModel = StateObject(wrappedValue: ReviewViewModel(environment: environment, parsedInvoice: parsedInvoice))
    }

    var body: some View {
        Form {
            if let error = viewModel.errorMessage, !error.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                reviewHealthCard
            }

            Section("Vendor") {
                vendorSection
            }

            Section {
                identifierSection
            } header: {
                Text("Invoice & PO")
            } footer: {
                if viewModel.confidenceScore < 0.75 {
                    Label("Some fields may need review.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }

            Section("Line Items") {
                if canFilterNeedsReview {
                    Toggle("Focus on items needing review", isOn: $focusNeedsReviewOnly)
                        .accessibilityIdentifier("review.focusNeedsReviewToggle")
                }

                itemsList

                Button {
                    viewModel.addEmptyItem()
                } label: {
                    Label("Add Line Item", systemImage: "plus")
                }
            }

            Section("Submission") {
                submissionModePicker
                submissionContextLinks
                taxBehaviorRow
            }

            Section("Totals") {
                LabeledContent("Subtotal", value: viewModel.subtotalFormatted)
                if !viewModel.shouldIgnoreTax {
                    LabeledContent("Tax", value: viewModel.taxFormatted)
                }
                LabeledContent("Total", value: viewModel.grandTotalFormatted)
                    .font(.headline)
                LabeledContent("Scans Today", value: "\(viewModel.todayCount)")
            }

            Section("Notes") {
                TextEditor(text: $viewModel.notes)
                    .frame(minHeight: 120)
            }

            #if DEBUG
            Section("Debug Metrics") {
                LabeledContent("Unknown Type Rate", value: percentageString(viewModel.unknownKindRate))
                LabeledContent("Type Overrides", value: String(viewModel.typeOverrideCount))
                LabeledContent("Vendor Auto-Select", value: percentageString(viewModel.vendorAutoSelectSuccessRate))
            }
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(backgroundLayer)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(viewModel.isSubmitting ? "Submitting..." : "Submit") {
                    Task { await viewModel.submitTapped() }
                }
                .disabled(!viewModel.canSubmit || viewModel.isSubmitting)
                .accessibilityIdentifier("review.submitButton")
            }
        }
        .alert("Submitted", isPresented: $viewModel.showSuccessAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("Parts were submitted to the Shopmonkey sandbox.")
        }
        .onAppear {
            viewModel.loadTodayMetrics()
        }
    }

    private var backgroundLayer: some View {
        AppScreenBackground()
    }

    private var reviewHealthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Review Readiness")
                    .font(.headline)
                Spacer()
                Text("\(Int((viewModel.reviewReadinessScore * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: viewModel.reviewReadinessScore)

            HStack(spacing: 8) {
                statusPill(title: "\(viewModel.items.count) line items", color: .blue)
                statusPill(title: "\(viewModel.unknownKindCount) unknown", color: .orange)
            }

            Text(viewModel.canSubmit ? "Required fields complete." : "Pick a vendor match and required IDs before submitting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review.readinessHint")
        }
        .padding(.vertical, 2)
    }

    private var vendorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusPill(
                    title: viewModel.selectedVendorId == nil ? "Vendor not selected" : "Vendor selected",
                    color: viewModel.selectedVendorId == nil ? .orange : .green
                )
                if let suggestedVendorName = viewModel.suggestedVendorName, !suggestedVendorName.isEmpty {
                    Text("OCR suggested: \(suggestedVendorName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TextField(
                viewModel.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedVendorName ?? "Vendor")
                    : "Vendor",
                text: Binding(
                    get: { viewModel.vendorName },
                    set: { viewModel.setVendorName($0) }
                )
            )
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("review.vendorField")

            if viewModel.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedVendorName = viewModel.suggestedVendorName,
               !suggestedVendorName.isEmpty {
                Button("Use vendor suggestion: \(suggestedVendorName)") {
                    viewModel.applySuggestedVendorName()
                }
                .font(.caption)
            }

            if !viewModel.vendorSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.vendorSuggestions.prefix(5)) { vendor in
                        Button {
                            viewModel.selectVendorSuggestion(vendor)
                        } label: {
                            HStack {
                                Text(vendor.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if viewModel.selectedVendorId == vendor.id ||
                                    vendor.name.normalizedVendorName == viewModel.vendorName.normalizedVendorName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var identifierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                viewModel.vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedInvoiceNumber ?? "Vendor Invoice Number")
                    : "Vendor Invoice Number",
                text: $viewModel.vendorInvoiceNumber
            )
            .textInputAutocapitalization(.characters)

            if viewModel.vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedInvoice = viewModel.suggestedInvoiceNumber,
               !suggestedInvoice.isEmpty {
                Button("Use invoice suggestion: \(suggestedInvoice)") {
                    viewModel.applySuggestedInvoiceNumber()
                }
                .font(.caption)
            }

            TextField(
                viewModel.poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedPONumber ?? "PO Reference (optional)")
                    : "PO Reference (optional)",
                text: $viewModel.poReference
            )
            .textInputAutocapitalization(.characters)

            if viewModel.poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedPO = viewModel.suggestedPONumber,
               !suggestedPO.isEmpty {
                Button("Use PO suggestion: \(suggestedPO)") {
                    viewModel.applySuggestedPONumber()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var submissionModePicker: some View {
        Picker("Mode", selection: $viewModel.modeUI) {
            Text("Attach to PO").tag(ReviewViewModel.ModeUI.attach)
            Text("Quick Add").tag(ReviewViewModel.ModeUI.quickAdd)
            Text("Restock").tag(ReviewViewModel.ModeUI.restock)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("review.modePicker")
    }

    @ViewBuilder
    private var submissionContextLinks: some View {
        switch viewModel.modeUI {
        case .attach:
            NavigationLink("Select Existing PO") {
                OrderPickerView(service: viewModel.shopmonkeyService) { order in
                    viewModel.selectOrder(order)
                }
            }

            TextField("Work Order ID", text: orderIdBinding)
            TextField("Service ID", text: serviceIdBinding)

        case .quickAdd:
            TextField("Work Order ID (for lookup)", text: orderIdBinding)

            if !orderIdBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NavigationLink("Select Ticket / Service") {
                    ServicePickerView(
                        service: viewModel.shopmonkeyService,
                        orderId: orderIdBinding.wrappedValue
                    ) { service in
                        viewModel.selectService(service)
                    }
                }
            }

            TextField("Ticket / Service ID", text: serviceIdBinding)

        case .restock:
            TextField("Work Order ID (optional)", text: orderIdBinding)
            TextField("Service ID (optional)", text: serviceIdBinding)
        }
    }

    private var taxBehaviorRow: some View {
        Toggle("Ignore tax and totals", isOn: $viewModel.ignoreTaxOverride)
    }

    @ViewBuilder
    private var itemsList: some View {
        if filteredItemIndices.isEmpty {
            Text("No line items match the current filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        ForEach(filteredItemIndices, id: \.self) { index in
            let itemBinding = $viewModel.items[index]
            NavigationLink {
                LineItemEditView(item: itemBinding) { oldKind, newKind in
                    viewModel.recordTypeOverride(from: oldKind, to: newKind)
                }
            } label: {
                lineItemRow(item: viewModel.items[index])
            }
        }
        .onDelete(perform: deleteFilteredItems)
    }

    private var canFilterNeedsReview: Bool {
        viewModel.unknownKindCount > 0 || viewModel.suggestedKindCount > 0
    }

    private var filteredItemIndices: [Int] {
        let allIndices = Array(viewModel.items.indices)
        guard focusNeedsReviewOnly, canFilterNeedsReview else { return allIndices }
        return allIndices.filter { index in
            let item = viewModel.items[index]
            return item.kind == .unknown || item.isKindConfidenceMedium
        }
    }

    private func deleteFilteredItems(at offsets: IndexSet) {
        let sourceIndices = offsets.compactMap { offset in
            filteredItemIndices.indices.contains(offset) ? filteredItemIndices[offset] : nil
        }
        let mapped = IndexSet(sourceIndices)
        viewModel.deleteItems(at: mapped)
    }

    private func lineItemRow(item: POItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Item" : item.description)
                .font(.body.weight(.semibold))

            HStack(spacing: 6) {
                Text(item.kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(kindBadgeColor(for: item))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                if item.kind == .unknown {
                    Text("Needs review")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if item.isKindConfidenceMedium {
                    Text("Suggested")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !item.sku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.sku)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Text("\(quantityString(item.quantity)) x \(item.unitPriceFormatted)")
                Spacer()
                Text(item.subtotalFormatted)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let feeHint = item.feeInferenceHint {
                Text(feeHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func kindBadgeColor(for item: POItem) -> Color {
        switch item.kind {
        case .part:
            return .blue
        case .tire:
            return .orange
        case .fee:
            return .teal
        case .unknown:
            return .gray
        }
    }

    private func statusPill(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }

    private func quantityString(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func percentageString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var orderIdBinding: Binding<String> {
        Binding(
            get: { viewModel.orderId },
            set: { viewModel.setOrderIdManually($0) }
        )
    }

    private var serviceIdBinding: Binding<String> {
        Binding(
            get: { viewModel.serviceId },
            set: { viewModel.setServiceIdManually($0) }
        )
    }
}
