//
//  LineItemEditView.swift
//  POScannerApp
//

import SwiftUI

struct LineItemEditView: View {
    @Binding var item: POItem
    var onKindChanged: ((POItemKind, POItemKind) -> Void)? = nil
    @State private var previousKind: POItemKind

    init(item: Binding<POItem>, onKindChanged: ((POItemKind, POItemKind) -> Void)? = nil) {
        self._item = item
        self.onKindChanged = onKindChanged
        self._previousKind = State(initialValue: item.wrappedValue.kind)
    }

    var body: some View {
        Form {
            Section {
                summaryCard
            }

            Section("Type") {
                Picker("Line Type", selection: $item.kind) {
                    Text(POItemKind.part.displayName).tag(POItemKind.part)
                    Text(POItemKind.tire.displayName).tag(POItemKind.tire)
                    Text(POItemKind.fee.displayName).tag(POItemKind.fee)
                    Text(POItemKind.unknown.displayName).tag(POItemKind.unknown)
                }
                .pickerStyle(.segmented)

                if item.kind == .unknown {
                    Label("Auto-classification needs review.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                } else if item.isKindConfidenceMedium {
                    Label("Suggested (\(Int((item.kindConfidence * 100).rounded()))%)", systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let feeHint = item.feeInferenceHint {
                    Label(feeHint, systemImage: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !item.kindReasons.isEmpty, !item.isKindConfidenceHigh {
                    Text(item.kindReasons.joined(separator: " • "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Line Item") {
                TextField("SKU / Part #", text: $item.sku)
                    .textInputAutocapitalization(.characters)

                TextField("Description", text: $item.description)
            }

            Section("Quantity & Cost") {
                TextField("Quantity", value: $item.quantity, format: .number)
                    .keyboardType(.decimalPad)

                TextField("Unit Cost", value: $item.unitCost, format: .currency(code: "USD"))
                    .keyboardType(.decimalPad)

                Toggle("Taxable", isOn: $item.isTaxable)
            }

            Section("Subtotal") {
                LabeledContent("Subtotal", value: item.subtotalFormatted)
                    .font(.headline)
            }
        }
        .scrollContentBackground(.hidden)
        .background(backgroundLayer)
        .navigationTitle("Line Item")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: item.kind) { oldValue, newValue in
            previousKind = newValue
            onKindChanged?(oldValue, newValue)
        }
    }

    private var backgroundLayer: some View {
        AppScreenBackground()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line Snapshot")
                .font(.headline)

            HStack(spacing: 8) {
                statusChip(title: item.kind.displayName, color: item.kind == .unknown ? .orange : .green)
                Text(item.subtotalFormatted)
                    .font(.subheadline.weight(.semibold))
            }

            Text("Confidence \(Int((item.kindConfidence * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func statusChip(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}
