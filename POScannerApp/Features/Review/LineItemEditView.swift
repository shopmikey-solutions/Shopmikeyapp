//
//  LineItemEditView.swift
//  POScannerApp
//

import SwiftUI

struct LineItemEditView: View {
    private enum FocusField: Hashable {
        case sku
        case description
        case quantity
        case unitCost
    }

    @Binding var item: POItem
    let allowTaxEditing: Bool
    var onKindChanged: ((POItemKind, POItemKind) -> Void)? = nil
    @FocusState private var focusedField: FocusField?

    init(
        item: Binding<POItem>,
        allowTaxEditing: Bool = true,
        onKindChanged: ((POItemKind, POItemKind) -> Void)? = nil
    ) {
        self._item = item
        self.allowTaxEditing = allowTaxEditing
        self.onKindChanged = onKindChanged
    }

    var body: some View {
        List {
            Section("Summary") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        statusChip(title: item.kind.displayName, color: item.kind == .unknown ? AppSurfaceStyle.warning : AppSurfaceStyle.success)
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
                        .foregroundStyle(AppSurfaceStyle.warning)
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
                    .focused($focusedField, equals: .sku)
                    .submitLabel(.next)

                TextField("Description", text: $item.description)
                    .focused($focusedField, equals: .description)
                    .submitLabel(.next)
            }

            Section("Quantity & Cost") {
                TextField("Quantity", value: $item.quantity, format: .number)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .quantity)
                    .submitLabel(.next)

                Stepper(value: $item.quantity, in: 1...999, step: 1) {
                    LabeledContent("Adjust Quantity", value: quantityString(item.quantity))
                }
                .onChange(of: item.quantity) { oldValue, newValue in
                    guard oldValue != newValue, focusedField != .quantity else { return }
                    AppHaptics.selection()
                }

                TextField("Unit Cost", value: $item.unitCost, format: .currency(code: "USD"))
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .unitCost)
                    .submitLabel(.done)

                Toggle("Taxable", isOn: $item.isTaxable)
                    .disabled(!allowTaxEditing)

                if !allowTaxEditing {
                    Text("Tax is managed by global Parts Intake Preferences.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Subtotal") {
                LabeledContent("Line Total", value: item.subtotalFormatted)
                    .font(.headline)
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .keyboardDoneToolbar()
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Line Item")
        .navigationBarTitleDisplayMode(.inline)
        .onSubmit {
            switch focusedField {
            case .sku:
                focusedField = .description
            case .description:
                focusedField = .quantity
            case .quantity:
                focusedField = .unitCost
            case .unitCost:
                focusedField = nil
            case .none:
                break
            }
        }
        .onChange(of: item.kind) { oldValue, newValue in
            onKindChanged?(oldValue, newValue)
        }
        .onAppear {
            if !allowTaxEditing, item.isTaxable {
                item.isTaxable = false
            }
        }
        .onChange(of: item.isTaxable) { _, _ in
            if !allowTaxEditing {
                if item.isTaxable {
                    item.isTaxable = false
                }
                return
            }
            AppHaptics.selection()
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
