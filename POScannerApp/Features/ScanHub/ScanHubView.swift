//
//  ScanHubView.swift
//  POScannerApp
//

import SwiftUI

struct ScanHubView: View {
    let environment: AppEnvironment
    let requestTabSwitch: (RootTab) -> Void

    @StateObject private var viewModel: ScanHubViewModel
    @State private var route: ScanHubRoute?
    @State private var isBarcodeScannerPresented = false

    init(
        environment: AppEnvironment,
        requestTabSwitch: @escaping (RootTab) -> Void = { _ in }
    ) {
        self.environment = environment
        self.requestTabSwitch = requestTabSwitch
        _viewModel = StateObject(
            wrappedValue: ScanHubViewModel(
                inventoryStore: environment.inventoryStore,
                ticketStore: environment.ticketStore,
                purchaseOrderStore: environment.purchaseOrderStore,
                reviewDraftStore: environment.reviewDraftStore
            )
        )
    }

    var body: some View {
        List {
            scanAndImportSection
            smartSuggestionSection
            activeContextSection
            recentActivitySection
            quickNavigationSection
            uiTestSection
        }
        .navigationTitle("ShopMikey")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $route) { destination in
            destinationView(for: destination)
        }
        .fullScreenCover(isPresented: $isBarcodeScannerPresented) {
            OperationalBarcodeScannerView { scannedCode in
                Task { @MainActor in
                    await viewModel.handleScannedCode(scannedCode)
                    isBarcodeScannerPresented = false
                    AppHaptics.success()
                }
            }
        }
        .task {
            await viewModel.loadInitialState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDraftStoreDidChange)) { _ in
            Task { @MainActor in
                await viewModel.refreshRecentActivity()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appOpenScanComposer)) { _ in
            route = .scanWorkflow(.openComposer)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appResumeScanDraft)) { notification in
            guard let draftID = notification.object as? UUID else { return }
            route = .scanWorkflow(.resumeDraft(draftID))
        }
    }

    private var scanAndImportSection: some View {
        Section("Scan & Import") {
            quickActionButton(
                title: "Scan Document",
                subtitle: "Capture a paper invoice with the document camera.",
                systemImage: "doc.viewfinder",
                accessibilityIdentifier: "scanHub.scanDocument"
            ) {
                route = .scanWorkflow(.cameraDocument)
            }

            quickActionButton(
                title: "Add from Photo",
                subtitle: "Import a photo from your library into OCR review.",
                systemImage: "photo.on.rectangle",
                accessibilityIdentifier: "scanHub.importPhoto"
            ) {
                route = .scanWorkflow(.addFromPhoto)
            }

            quickActionButton(
                title: "Add from Files",
                subtitle: "Import image or PDF files into OCR review.",
                systemImage: "folder",
                accessibilityIdentifier: "scanHub.importFiles"
            ) {
                route = .scanWorkflow(.addFromFiles)
            }

            quickActionButton(
                title: "Scan Barcode",
                subtitle: "Scan a part barcode for operational suggestions.",
                systemImage: "barcode.viewfinder",
                accessibilityIdentifier: "scanHub.scanBarcode"
            ) {
                isBarcodeScannerPresented = true
            }
        }
    }

    @ViewBuilder
    private var smartSuggestionSection: some View {
        Section("Smart Suggestions / Last Scan") {
            if let lastScannedCode = viewModel.lastScannedCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last scanned code")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(lastScannedCode)
                        .font(.headline.monospaced())
                }
                .accessibilityIdentifier("scanHub.lastScanCard")

                switch viewModel.scanSuggestion {
                case .receivePO(let poID, _):
                    Button("Receive against PO \(poID)") {
                        route = .receivePurchaseOrder(id: poID, scannedCode: viewModel.lastScannedCode)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scanHub.suggestion.receivePO")

                case .addToTicket:
                    Button("Add to Active Ticket") {
                        route = .inventoryLookup(scannedCode: viewModel.lastScannedCode)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scanHub.suggestion.addToTicket")

                case .addToPODraft:
                    Button("Restock in PO Draft") {
                        route = .inventoryLookup(scannedCode: viewModel.lastScannedCode)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scanHub.suggestion.addToPODraft")

                case .none:
                    Text("No high-priority suggestion for this code. Use manual flow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Clear Last Scan") {
                    viewModel.clearLastScan()
                }
                .buttonStyle(.bordered)
            } else {
                Text("Scan a barcode to compute a suggested next step.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeContextSection: some View {
        Section("Active Context") {
            labeledValueRow(title: "Active Ticket", value: viewModel.activeTicketLabel ?? "None selected")
            labeledValueRow(title: "Selected Service", value: viewModel.activeServiceID ?? "None selected")
            labeledValueRow(
                title: "Active Receiving PO",
                value: viewModel.activeReceivingPurchaseOrderID ?? "None selected"
            )
            labeledValueRow(
                title: "Inventory Sync",
                value: viewModel.lastInventorySyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
            )
        }
    }

    private var recentActivitySection: some View {
        Section("Recent Activity") {
            labeledValueRow(title: "In-Progress Drafts", value: "\(viewModel.inProgressDraftCount)")
            if let latestDraftSummary = viewModel.latestDraftSummary {
                labeledValueRow(title: "Latest Draft", value: latestDraftSummary)
            }

            Button("Open Submission History") {
                route = .history
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scanHub.openHistory")
        }
    }

    private var quickNavigationSection: some View {
        Section("Quick Navigation") {
            labeledValueRow(title: "Open Tickets", value: "\(viewModel.openTicketCount)")
            labeledValueRow(title: "Open Purchase Orders", value: "\(viewModel.openPurchaseOrderCount)")

            Button("Go to Inventory") {
                requestTabSwitch(.inventory)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scanHub.goToInventory")

            Button("Go to Purchase Orders") {
                requestTabSwitch(.inventory)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scanHub.goToPurchaseOrders")

            Button("Go to Tickets") {
                requestTabSwitch(.tickets)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scanHub.goToTickets")

            Button("Go to Sync Health") {
                requestTabSwitch(.settings)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scanHub.goToSyncHealth")
        }
    }

    @ViewBuilder
    private var uiTestSection: some View {
        if ProcessInfo.processInfo.arguments.contains("-ui-test-review-fixture") {
            Section {
                Button("Open Review Fixture") {
                    route = .scanWorkflow(.openReviewFixture)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scanHub.openReviewFixture")
            }
        }
    }

    @ViewBuilder
    private func destinationView(for destination: ScanHubRoute) -> some View {
        switch destination {
        case .scanWorkflow(let action):
            ScanView(environment: environment, launchAction: action)
        case .inventoryLookup(let scannedCode):
            InventoryLookupView(environment: environment, prefilledScannedCode: scannedCode)
        case .receivePurchaseOrder(let id, let scannedCode):
            ReceiveItemView(environment: environment, purchaseOrderID: id, prefilledScannedCode: scannedCode)
        case .purchaseOrderDraft:
            POBuilderView(environment: environment)
        case .inventory:
            InventoryView(environment: environment)
        case .tickets:
            TicketsView(environment: environment)
        case .purchaseOrders:
            PurchaseOrdersView(environment: environment)
        case .history:
            HistoryView(environment: environment)
        case .settings:
            SettingsView(environment: environment)
        }
    }

    @ViewBuilder
    private func quickActionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ScanHubQuickActionRow(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func labeledValueRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}
