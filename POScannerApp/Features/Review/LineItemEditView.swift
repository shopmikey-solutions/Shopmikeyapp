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
        .navigationTitle("Line Item")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: item.kind) { oldValue, newValue in
            previousKind = newValue
            onKindChanged?(oldValue, newValue)
        }
    }
}
