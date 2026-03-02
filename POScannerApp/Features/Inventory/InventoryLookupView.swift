//
//  InventoryLookupView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking

struct InventoryLookupView: View {
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: InventoryLookupViewModel
    @State private var activeTicketContext: ActiveTicketContext
    @State private var isScannerPresented = false
    @State private var isTicketPickerPresented = false
    @State private var isDuplicateChoicePresented = false
    @State private var isManualDraftEntryPresented = false
    @State private var isSuggestedReceivePresented = false
    @State private var suggestedReceivePOID: String?
    @State private var pendingTicketIDForAdd: String?
    @State private var manualDraftDescription = ""
    @State private var manualDraftQuantity = "1"
    @State private var manualDraftUnitCost = ""

    init(environment: AppEnvironment) {
        self.environment = environment
        let shopmonkeyAPI = environment.shopmonkeyAPI
        _viewModel = StateObject(
            wrappedValue: InventoryLookupViewModel(
                inventoryStore: environment.inventoryStore,
                ticketStore: environment.ticketStore,
                purchaseOrderStore: environment.purchaseOrderStore,
                syncOperationQueue: environment.syncOperationQueue,
                syncEngine: environment.syncEngine,
                dateProvider: environment.dateProvider,
                serviceResolver: { [shopmonkeyAPI] orderID in
                    try await shopmonkeyAPI.fetchServices(orderId: orderID)
                }
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
        .sheet(isPresented: $isSuggestedReceivePresented) {
            if let suggestedReceivePOID {
                NavigationStack {
                    ReceiveItemView(environment: environment, purchaseOrderID: suggestedReceivePOID)
                }
            }
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.scanSuggestion)
        .onChange(of: viewModel.ticketMutationState) { _, state in
            if case .succeeded = state {
                AppHaptics.success()
            }
        }
        .onChange(of: viewModel.draftMutationMessage) { _, message in
            guard let message, message.lowercased().contains("added") else { return }
            AppHaptics.success()
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

                suggestionBanner(matchedItem: item)
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
                    if let activeServiceID = activeTicketContext.activeServiceID {
                        labeledRow("Selected Service", value: activeServiceID)
                    } else {
                        Text("Service not selected for this ticket.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("inventory.lookup.serviceMissing")
                    }
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

                suggestionBanner(matchedItem: nil)

                Button("Add to PO Draft") {
                    openManualDraftSheetPrefilled()
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

        await handleAddToTicket(ticketID: activeTicketID)
    }

    @MainActor
    private func handleAddToTicket(ticketID: String) async {
        if await viewModel.hasDuplicateMatch(in: ticketID) {
            pendingTicketIDForAdd = ticketID
            isDuplicateChoicePresented = true
            return
        }

        pendingTicketIDForAdd = ticketID
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

    private func openManualDraftSheetPrefilled() {
        manualDraftDescription = viewModel.scannedCode ?? ""
        manualDraftQuantity = "1"
        manualDraftUnitCost = ""
        isManualDraftEntryPresented = true
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

    @ViewBuilder
    private func suggestionBanner(matchedItem: InventoryItem?) -> some View {
        switch viewModel.scanSuggestion {
        case .receivePO(let poID, _):
            suggestionCard(
                title: "Suggested next step",
                detail: "Receive item against PO \(poID)?"
            ) {
                Button("Receive against PO") {
                    suggestedReceivePOID = poID
                    isSuggestedReceivePresented = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("inventory.lookup.suggestion.receivePO")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))

        case .addToTicket(let ticketID):
            suggestionCard(
                title: "Suggested next step",
                detail: "Add this item to active ticket \(ticketID)?"
            ) {
                Button("Add to Active Ticket") {
                    Task { @MainActor in
                        await handleAddToTicket(ticketID: ticketID)
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("inventory.lookup.suggestion.addToTicket")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))

        case .addToPODraft:
            suggestionCard(
                title: "Suggested next step",
                detail: "Stock is low. Add this item to PO Draft?"
            ) {
                Button("Restock in PO Draft") {
                    Task { @MainActor in
                        if let matchedItem {
                            await addMatchedItemToDraft(matchedItem)
                        } else {
                            openManualDraftSheetPrefilled()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("inventory.lookup.suggestion.addToPODraft")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))

        case .none:
            EmptyView()
        }
    }

    private func suggestionCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("inventory.lookup.suggestionBanner")
    }
}
