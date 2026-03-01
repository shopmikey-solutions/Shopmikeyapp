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
    @State private var activeTicketContext: ActiveTicketContext
    @State private var isScannerPresented = false
    @State private var isTicketPickerPresented = false
    @State private var isDuplicateChoicePresented = false
    @State private var isManualDraftEntryPresented = false
    @State private var pendingTicketIDForAdd: String?
    @State private var manualDraftDescription = ""
    @State private var manualDraftQuantity = "1"
    @State private var manualDraftUnitCost = ""

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(
            wrappedValue: InventoryLookupViewModel(
                inventoryStore: environment.inventoryStore,
                ticketStore: environment.ticketStore,
                syncOperationQueue: environment.syncOperationQueue,
                syncEngine: environment.syncEngine,
                dateProvider: environment.dateProvider
            )
        )
        _activeTicketContext = State(initialValue: ActiveTicketContext(
            ticketStore: environment.ticketStore,
            shopmonkeyAPI: environment.shopmonkeyAPI
        ))
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
        .sheet(isPresented: $isTicketPickerPresented) {
            TicketPickerView(context: activeTicketContext)
        }
        .sheet(isPresented: $isManualDraftEntryPresented) {
            manualDraftEntrySheet
        }
        .confirmationDialog(
            "Matching ticket line found",
            isPresented: $isDuplicateChoicePresented,
            titleVisibility: .visible
        ) {
            Button("Increment Quantity") {
                Task { @MainActor in
                    await performAddToTicket(mergeMode: .incrementQuantity)
                }
            }
            Button("Add New Line") {
                Task { @MainActor in
                    await performAddToTicket(mergeMode: .addNewLine)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTicketIDForAdd = nil
            }
        } message: {
            Text("An item with the same SKU or part number exists in this ticket.")
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
        .task {
            await activeTicketContext.loadCachedState()
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

                Divider()

                Button("Add to PO Draft") {
                    Task { @MainActor in
                        await addMatchedItemToDraft(item)
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("inventory.lookup.addToPODraftButton")

                NavigationLink {
                    POBuilderView(environment: environment)
                } label: {
                    Text("Open PO Draft")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inventory.lookup.openPODraftButton")

                if let activeTicket = activeTicketContext.activeTicket {
                    labeledRow(
                        "Active Ticket",
                        value: activeTicket.displayNumber ?? activeTicket.number ?? activeTicket.id
                    )
                    Button("Add to Active Ticket") {
                        Task { @MainActor in
                            await handleAddToActiveTicketTapped()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("inventory.lookup.addToActiveTicketButton")

                    Button("Change Ticket") {
                        isTicketPickerPresented = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("inventory.lookup.changeTicketButton")
                } else {
                    Text("No active ticket selected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Select Ticket") {
                        isTicketPickerPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("inventory.lookup.selectTicketButton")
                }

                if let ticketMutationMessage = viewModel.ticketMutationMessage {
                    Text(ticketMutationMessage)
                        .font(.footnote)
                        .foregroundStyle(ticketMutationColor)
                        .accessibilityIdentifier("inventory.lookup.ticketMutationMessage")
                }

                if let draftMutationMessage = viewModel.draftMutationMessage {
                    Text(draftMutationMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("inventory.lookup.draftMutationMessage")
                }
            }
            .accessibilityIdentifier("inventory.lookup.matchFound")

        case .noMatch:
            VStack(alignment: .leading, spacing: 8) {
                Text("No match")
                    .font(.title3.weight(.semibold))
                Text("No match found in inventory.")
                    .foregroundStyle(.secondary)

                Button("Add to PO Draft") {
                    manualDraftDescription = viewModel.scannedCode ?? ""
                    manualDraftQuantity = "1"
                    manualDraftUnitCost = ""
                    isManualDraftEntryPresented = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("inventory.lookup.addUnknownToPODraftButton")

                NavigationLink {
                    POBuilderView(environment: environment)
                } label: {
                    Text("Open PO Draft")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inventory.lookup.openPODraftButtonNoMatch")

                if let draftMutationMessage = viewModel.draftMutationMessage {
                    Text(draftMutationMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("inventory.lookup.draftMutationMessageNoMatch")
                }
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

    @MainActor
    private func handleAddToActiveTicketTapped() async {
        guard let activeTicketID = activeTicketContext.activeTicketID else {
            isTicketPickerPresented = true
            return
        }

        if await viewModel.hasDuplicateMatch(in: activeTicketID) {
            pendingTicketIDForAdd = activeTicketID
            isDuplicateChoicePresented = true
            return
        }

        pendingTicketIDForAdd = activeTicketID
        await performAddToTicket(mergeMode: .addNewLine)
    }

    @MainActor
    private func performAddToTicket(mergeMode: TicketLineMergeMode) async {
        let ticketID = pendingTicketIDForAdd ?? activeTicketContext.activeTicketID
        await viewModel.addMatchedItemToTicket(ticketID: ticketID, mergeMode: mergeMode)
        pendingTicketIDForAdd = nil
        await activeTicketContext.refreshOpenTickets(forceRemote: false)
    }

    @MainActor
    private func addMatchedItemToDraft(_ item: InventoryItem) async {
        let line = viewModel.matchedItemDraftLine() ?? PurchaseOrderDraftLine(
            sku: normalizedOptionalString(item.sku),
            partNumber: normalizedOptionalString(item.partNumber),
            description: item.description,
            quantity: 1,
            unitCost: item.price > .zero ? item.price : nil,
            sourceBarcode: viewModel.scannedCode
        )
        _ = await environment.purchaseOrderDraftStore.addLine(line)
        viewModel.setDraftMutationMessage("Added to PO Draft.")
    }

    @MainActor
    private func addManualItemToDraft() async {
        guard let quantity = Decimal(string: manualDraftQuantity.trimmingCharacters(in: .whitespacesAndNewlines)),
              quantity >= 1 else {
            viewModel.setDraftMutationMessage("Enter a valid quantity before adding.")
            return
        }

        let unitCost: Decimal?
        let trimmedUnitCost = manualDraftUnitCost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUnitCost.isEmpty {
            unitCost = nil
        } else {
            unitCost = Decimal(string: trimmedUnitCost)
        }

        guard let line = viewModel.manualDraftLine(
            description: manualDraftDescription,
            quantity: quantity,
            unitCost: unitCost
        ) else {
            viewModel.setDraftMutationMessage("Description is required before adding.")
            return
        }

        _ = await environment.purchaseOrderDraftStore.addLine(line)
        viewModel.setDraftMutationMessage("Added unknown item to PO Draft.")
        isManualDraftEntryPresented = false
    }

    private var ticketMutationColor: Color {
        switch viewModel.ticketMutationState {
        case .succeeded:
            return .green
        case .queued:
            return .orange
        case .failed:
            return .red
        case .idle, .adding:
            return .secondary
        }
    }

    private var manualDraftEntrySheet: some View {
        NavigationStack {
            Form {
                TextField("Description", text: $manualDraftDescription)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("inventory.lookup.manualDraftDescriptionField")

                TextField("Quantity", text: $manualDraftQuantity)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("inventory.lookup.manualDraftQuantityField")

                TextField("Unit Cost (optional)", text: $manualDraftUnitCost)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("inventory.lookup.manualDraftUnitCostField")
            }
            .navigationTitle("Add to PO Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isManualDraftEntryPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { @MainActor in
                            await addManualItemToDraft()
                        }
                    }
                    .accessibilityIdentifier("inventory.lookup.manualDraftAddButton")
                }
            }
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

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
