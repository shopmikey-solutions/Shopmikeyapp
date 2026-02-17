//
//  LineItemEditView.swift
//  POScannerApp
//

import SwiftUI

struct LineItemEditView: View {
    @Binding var item: POItem
    var onKindChanged: ((POItemKind, POItemKind) -> Void)? = nil

    init(item: Binding<POItem>, onKindChanged: ((POItemKind, POItemKind) -> Void)? = nil) {
        self._item = item
        self.onKindChanged = onKindChanged
    }

    var body: some View {
        List {
            Section("Summary") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        statusChip(title: item.kind.displayName, color: item.kind == .unknown ? .orange : .green)
                        Text(item.subtotalFormatted)
                            .font(.headline)
                    }
                    Text("Confidence \(Int((item.kindConfidence * 100).rounded()))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Type") {
                NativeSegmentedControl(
                    options: [POItemKind.part, .tire, .fee, .unknown],
                    titleForOption: { $0.displayName },
                    selection: $item.kind
                )

                if item.kind == .unknown {
                    Label("Auto-classification needs review.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if item.isKindConfidenceMedium {
                    Label("Suggested (\(Int((item.kindConfidence * 100).rounded()))%)", systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let feeHint = item.feeInferenceHint {
                    Label(feeHint, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !item.kindReasons.isEmpty, !item.isKindConfidenceHigh {
                    Text(item.kindReasons.joined(separator: " • "))
                        .font(.caption)
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

                Stepper(value: $item.quantity, in: 1...999, step: 1) {
                    LabeledContent("Adjust Quantity", value: quantityString(item.quantity))
                }

                TextField("Unit Cost", value: $item.unitCost, format: .currency(code: "USD"))
                    .keyboardType(.decimalPad)

                Toggle("Taxable", isOn: $item.isTaxable)
            }

            Section("Subtotal") {
                LabeledContent("Line Total", value: item.subtotalFormatted)
                    .font(.headline)
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("Line Item")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: item.kind) { oldValue, newValue in
            onKindChanged?(oldValue, newValue)
        }
    }

    private func statusChip(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
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
}

#if DEBUG
private struct LineItemEditPreviewContainer: View {
    @State private var item: POItem = PreviewFixtures.lineItem

    var body: some View {
        NavigationStack {
            LineItemEditView(item: $item)
        }
    }
}

#Preview("Line Item Edit") {
    LineItemEditPreviewContainer()
}
#endif
