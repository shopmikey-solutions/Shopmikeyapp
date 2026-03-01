//
//  POBuilderView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreModels

struct POBuilderView: View {
    let environment: AppEnvironment

    @StateObject private var viewModel: POBuilderViewModel
    @State private var vendorNameInput: String = ""
    @State private var unitCostInputs: [UUID: String] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(
            wrappedValue: POBuilderViewModel(
                environment: environment,
                draftStore: environment.purchaseOrderDraftStore
            )
        )
    }

    var body: some View {
        List {
            Section("Vendor") {
                TextField("Vendor name", text: $vendorNameInput)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("poBuilder.vendorNameField")
                    .onSubmit {
                        Task { @MainActor in
                            await viewModel.updateVendorNameHint(vendorNameInput)
                        }
                    }
            }

            if viewModel.lines.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No draft lines yet")
                            .font(.subheadline.weight(.semibold))
                        Text("Add lines from Inventory Lookup to build a restock purchase order.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("poBuilder.emptyState")
                }
            } else {
                Section("Line Items") {
                    ForEach(viewModel.lines) { line in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(line.description)
                                .font(.headline)

                            HStack(spacing: 12) {
                                Stepper(
                                    value: quantityBinding(for: line),
                                    in: 1...999
                                ) {
                                    Text("Qty \(quantityText(for: line))")
                                        .font(.subheadline)
                                }
                                .accessibilityIdentifier("poBuilder.qtyStepper.\(line.id.uuidString)")

                                TextField(
                                    "Unit Cost",
                                    text: unitCostBinding(for: line)
                                )
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                                .onSubmit {
                                    Task { @MainActor in
                                        await commitUnitCost(for: line)
                                    }
                                }
                                .accessibilityIdentifier("poBuilder.unitCostField.\(line.id.uuidString)")
                            }

                            HStack {
                                if let sku = normalizedOptionalString(line.sku) {
                                    Text("SKU: \(sku)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if let partNumber = normalizedOptionalString(line.partNumber) {
                                    Text("PN: \(partNumber)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { @MainActor in
                                    await viewModel.removeLine(id: line.id)
                                    unitCostInputs.removeValue(forKey: line.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Section("Summary") {
                    HStack {
                        Text("Total")
                        Spacer()
                        Text(viewModel.totalAmountFormatted)
                            .fontWeight(.semibold)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { @MainActor in
                        await viewModel.clearDraft()
                        vendorNameInput = ""
                        unitCostInputs.removeAll()
                    }
                } label: {
                    Text("Clear Draft")
                }
                .disabled(!viewModel.hasDraftLines)
                .accessibilityIdentifier("poBuilder.clearDraftButton")

                Button {
                    Task { @MainActor in
                        await viewModel.updateVendorNameHint(vendorNameInput)
                        await viewModel.submitDraft()
                    }
                } label: {
                    if viewModel.isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Submitting…")
                        }
                    } else {
                        Text("Submit Draft")
                    }
                }
                .disabled(viewModel.isSubmitting || !viewModel.hasDraftLines)
                .accessibilityIdentifier("poBuilder.submitDraftButton")
            }

            if let statusMessage = viewModel.statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("poBuilder.statusMessage")
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("poBuilder.errorMessage")
                    if let diagnosticCode = viewModel.lastDiagnosticCode {
                        Text("Diagnostic ID: \(diagnosticCode)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("poBuilder.errorDiagnosticCode")
                    }
                }
            }
        }
        .navigationTitle("PO Draft")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.2), value: viewModel.lines)
        .task {
            await viewModel.loadDraft()
            syncLocalStateFromDraft()
        }
        .onChange(of: viewModel.draft) { _, _ in
            syncLocalStateFromDraft()
        }
        .onChange(of: viewModel.statusMessage) { _, statusMessage in
            guard let statusMessage, !statusMessage.isEmpty else { return }
            AppHaptics.success()
        }
    }

    private func syncLocalStateFromDraft() {
        vendorNameInput = viewModel.vendorNameHint
        var nextInputs: [UUID: String] = [:]
        for line in viewModel.lines {
            nextInputs[line.id] = formattedUnitCost(line.unitCost)
        }
        unitCostInputs = nextInputs
    }

    private func quantityBinding(for line: PurchaseOrderDraftLine) -> Binding<Int> {
        Binding<Int>(
            get: {
                max(1, NSDecimalNumber(decimal: line.quantity).intValue)
            },
            set: { newValue in
                Task { @MainActor in
                    let unitCost = parsedUnitCost(for: line)
                    await viewModel.updateLine(
                        id: line.id,
                        quantity: Decimal(max(1, newValue)),
                        unitCost: unitCost
                    )
                }
            }
        )
    }

    private func unitCostBinding(for line: PurchaseOrderDraftLine) -> Binding<String> {
        Binding<String>(
            get: {
                unitCostInputs[line.id] ?? formattedUnitCost(line.unitCost)
            },
            set: { newValue in
                unitCostInputs[line.id] = newValue
            }
        )
    }

    @MainActor
    private func commitUnitCost(for line: PurchaseOrderDraftLine) async {
        let value = parsedUnitCost(for: line)
        await viewModel.updateLine(
            id: line.id,
            quantity: line.quantity,
            unitCost: value
        )
    }

    private func parsedUnitCost(for line: PurchaseOrderDraftLine) -> Decimal? {
        let raw = unitCostInputs[line.id] ?? formattedUnitCost(line.unitCost)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed)
    }

    private func quantityText(for line: PurchaseOrderDraftLine) -> String {
        NSDecimalNumber(decimal: max(1, line.quantity)).stringValue
    }

    private func formattedUnitCost(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
