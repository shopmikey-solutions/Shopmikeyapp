//
//  ReviewView.swift
//  POScannerApp
//

import SwiftUI

struct ReviewView: View {
    @StateObject var viewModel: ReviewViewModel
    @State private var showHeaderDetails: Bool = false
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
                headerCard
            } footer: {
                if viewModel.confidenceScore < 0.75 {
                    Label("Some fields may need review.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }

            Section("Line Items") {
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
        LinearGradient(
            colors: [
                Color(.systemGroupedBackground),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            DisclosureGroup("Header Details", isExpanded: $showHeaderDetails) {
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
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
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

    private var itemsList: some View {
        ForEach($viewModel.items) { $item in
            NavigationLink {
                LineItemEditView(item: $item) { oldKind, newKind in
                    viewModel.recordTypeOverride(from: oldKind, to: newKind)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Item" : item.description)
                        .font(.body)

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
                    }

                    Text("\(quantityString(item.quantity)) x \(item.unitPriceFormatted)  -  \(item.subtotalFormatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let feeHint = item.feeInferenceHint {
                        Text(feeHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onDelete(perform: viewModel.deleteItems)
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
