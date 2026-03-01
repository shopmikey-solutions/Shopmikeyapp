//
//  InventoryLookupView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreModels

struct InventoryLookupView: View {
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: InventoryLookupViewModel
    @State private var isScannerPresented = false

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(
            wrappedValue: InventoryLookupViewModel(inventoryStore: environment.inventoryStore)
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            stateContent
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                openScanner()
            } label: {
                Label("Scan Barcode", systemImage: "barcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("inventory.lookup.scanButton")

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Inventory Lookup")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isScannerPresented) {
            BarcodeScannerView { scannedCode in
                Task { @MainActor in
                    await viewModel.lookup(scannedCode: scannedCode)
                }
            }
        }
        .toolbar {
            if shouldShowDoneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("inventory.lookup.doneButton")
                }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to scan")
                    .font(.title3.weight(.semibold))
                Text("Scan a barcode to look up a matching inventory item.")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("inventory.lookup.idle")

        case .scanning:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                Text("Scanning for barcode…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("inventory.lookup.scanning")

        case .matchFound(let item):
            VStack(alignment: .leading, spacing: 10) {
                Text("Match found")
                    .font(.title3.weight(.semibold))
                labeledRow("Part Number", value: item.displayPartNumber)
                labeledRow("Description", value: item.description)
                labeledRow(
                    "Qty On Hand",
                    value: item.normalizedQuantityOnHand.formatted(.number.precision(.fractionLength(0...2)))
                )
            }
            .accessibilityIdentifier("inventory.lookup.matchFound")

        case .noMatch:
            VStack(alignment: .leading, spacing: 8) {
                Text("No match")
                    .font(.title3.weight(.semibold))
                Text("No match found in inventory.")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("inventory.lookup.noMatch")

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("Scanner unavailable")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("inventory.lookup.error")
        }
    }

    private var shouldShowDoneButton: Bool {
        switch viewModel.state {
        case .matchFound, .noMatch, .error:
            return true
        case .idle, .scanning:
            return false
        }
    }

    private func openScanner() {
        if BarcodeScannerView.isScannerAvailable {
            viewModel.startScanning()
            isScannerPresented = true
        } else {
            viewModel.setScannerUnavailable()
        }
    }

    @ViewBuilder
    private func labeledRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(title):")
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
