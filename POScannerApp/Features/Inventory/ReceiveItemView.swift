//
//  ReceiveItemView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import SwiftUI

struct ReceiveItemView: View {
    let environment: AppEnvironment
    let purchaseOrderID: String
    let prefilledScannedCode: String?

    @StateObject private var viewModel: ReceiveItemViewModel
    @State private var isScannerPresented = false
    @State private var quantityInput = "1"
    @State private var didApplyPrefilledScan = false

    init(environment: AppEnvironment, purchaseOrderID: String, prefilledScannedCode: String? = nil) {
        self.environment = environment
        self.purchaseOrderID = purchaseOrderID
        self.prefilledScannedCode = prefilledScannedCode
        _viewModel = StateObject(
            wrappedValue: ReceiveItemViewModel(
                purchaseOrderID: purchaseOrderID,
                shopmonkeyAPI: environment.shopmonkeyAPI,
                purchaseOrderStore: environment.purchaseOrderStore,
                inventoryStore: environment.inventoryStore,
                syncOperationQueue: environment.syncOperationQueue,
                syncEngine: environment.syncEngine,
                dateProvider: environment.dateProvider
            )
        )
    }

    var body: some View {
        List {
            if let detail = viewModel.purchaseOrderDetail {
                Section("Purchase Order") {
                    detailRow(label: "Vendor", value: detail.vendorName ?? "Unknown Vendor")
                    detailRow(label: "Status", value: detail.status ?? "Unknown")
                    detailRow(label: "Line Items", value: "\(detail.lineItems.count)")
                }

                Section("Receive") {
                    Button {
                        openScanner()
                    } label: {
                        Label("Scan Barcode", systemImage: "barcode.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("purchaseOrder.receive.scanButton")

                    if let scannedCode = viewModel.scannedCode {
                        detailRow(label: "Scanned", value: scannedCode)
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        Text(viewModel.statusIndicatorText.replacingOccurrences(of: "Status: ", with: ""))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusBadgeColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(statusBadgeColor)
                    }
                    .accessibilityIdentifier("purchaseOrder.receive.status")

                    matchContent

                    if let receiveMessage = viewModel.receiveMessage {
                        Text(receiveMessage)
                            .font(.footnote)
                            .foregroundStyle(receiveMessageColor)
                            .accessibilityIdentifier("purchaseOrder.receive.message")
                    }
                }

                Section("Line Items") {
                    if detail.lineItems.isEmpty {
                        Text("No line items available.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("purchaseOrder.receive.emptyLineItems")
                    } else {
                        ForEach(detail.lineItems) { lineItem in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(lineItem.description)
                                    .font(.headline)
                                HStack {
                                    Text("Ordered: \(decimalString(lineItem.quantityOrdered))")
                                    Text("Received: \(decimalString(lineItem.receivedQty))")
                                    if lineItem.isFullyReceived {
                                        Text("Received")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                if let partNumber = normalizedOptionalString(lineItem.partNumber) {
                                    Text("PN: \(partNumber)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("purchaseOrder.receive.line.\(lineItem.id)")
                        }
                    }
                }
            } else {
                Section {
                    ProgressView("Loading purchase order...")
                        .accessibilityIdentifier("purchaseOrder.receive.loading")
                }
            }
        }
        .navigationTitle("Receive Items")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("purchaseOrder.receive.list")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") {
                    Task { @MainActor in
                        await viewModel.refreshPurchaseOrderDetail()
                    }
                }
                .accessibilityIdentifier("purchaseOrder.receive.refreshButton")
            }
        }
        .fullScreenCover(isPresented: $isScannerPresented) {
            BarcodeScannerView { scannedCode in
                Task { @MainActor in
                    await viewModel.lookup(scannedCode: scannedCode)
                }
            }
        }
        .task {
            await viewModel.loadInitialDetail()
            await applyPrefilledScanIfNeeded()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.matchState)
        .onChange(of: viewModel.matchState) { _, newState in
            guard case .matched = newState else { return }
            quantityInput = viewModel.suggestedQuantityTextForMatchedLine()
        }
        .onChange(of: viewModel.receiveState) { _, receiveState in
            if case .succeeded = receiveState {
                AppHaptics.success()
            }
        }
    }

    @ViewBuilder
    private var matchContent: some View {
        switch viewModel.matchState {
        case .idle:
            Text("Scan a barcode to match a purchase order line item.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("purchaseOrder.receive.idle")

        case .scanning:
            ProgressView("Scanning...")
                .accessibilityIdentifier("purchaseOrder.receive.scanning")

        case .matched(let lineItem):
            VStack(alignment: .leading, spacing: 10) {
                Text("Matched Line Item")
                    .font(.headline)
                Text(lineItem.description)
                HStack {
                    Text("Ordered: \(decimalString(lineItem.quantityOrdered))")
                    Text("Received: \(decimalString(lineItem.receivedQty))")
                    Text("Remaining: \(decimalString(lineItem.remainingQty))")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if lineItem.isFullyReceived {
                    Text("Line fully received")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("purchaseOrder.receive.lineComplete")
                }

                TextField("Quantity Received", text: $quantityInput)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("purchaseOrder.receive.quantityField")

                Button("Confirm Receive") {
                    submitReceive()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canReceiveMatchedLine)
                .accessibilityIdentifier("purchaseOrder.receive.confirmButton")
            }
            .accessibilityIdentifier("purchaseOrder.receive.matched")

        case .noMatch:
            Text("No matching line item on this PO.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("purchaseOrder.receive.noMatch")

        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("purchaseOrder.receive.error")
        }
    }

    private var receiveMessageColor: Color {
        switch viewModel.receiveState {
        case .succeeded:
            return .green
        case .queued:
            return .orange
        case .failed:
            return .red
        case .idle, .receiving:
            return .secondary
        }
    }

    private var statusBadgeColor: Color {
        switch viewModel.receiveState {
        case .idle:
            return .secondary
        case .receiving:
            return .blue
        case .succeeded:
            return .green
        case .queued:
            return .orange
        case .failed:
            return .red
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

    private func submitReceive() {
        let trimmed = quantityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quantity = Decimal(string: trimmed), quantity > .zero else {
            quantityInput = "1"
            Task { @MainActor in
                await viewModel.receiveMatchedLine(quantity: 0)
            }
            return
        }

        Task { @MainActor in
            await viewModel.receiveMatchedLine(quantity: quantity)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func applyPrefilledScanIfNeeded() async {
        guard !didApplyPrefilledScan else { return }
        didApplyPrefilledScan = true
        guard let prefilledScannedCode else { return }
        await viewModel.lookup(scannedCode: prefilledScannedCode)
    }
}
