//
//  EditableItemRow.swift
//  POScannerApp
//

import SwiftUI

struct EditableItemRow: View {
    @Binding var item: POItem
    var onFocus: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("SKU", text: $item.sku)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .onTapGesture {
                        onFocus?()
                    }

                TextField("Description", text: $item.description)
                    .textFieldStyle(.roundedBorder)
                    .onTapGesture {
                        onFocus?()
                    }

                TextField("Qty", value: $item.quantity, format: .number)
                    .frame(width: 48)
                    .textFieldStyle(.roundedBorder)
                    .onTapGesture {
                        onFocus?()
                    }

                TextField("Cost", value: $item.unitCost, format: .currency(code: "USD"))
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .onTapGesture {
                        onFocus?()
                    }

                Text(item.subtotalFormatted)
                    .frame(width: 90, alignment: .trailing)
                    .fontWeight(.semibold)
            }
            .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .contextMenu {
                    Button {
                        onSelect?()
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }

                    if let onDuplicate {
                        Button {
                            onDuplicate()
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    }

                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

            Toggle("Taxable", isOn: $item.isTaxable)
                .font(.caption)
                .tint(AppSurfaceStyle.accent)

            Divider()
                .background(Color.white.opacity(0.2))
        }
    }
}
