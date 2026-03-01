//
//  InventoryView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import ShopmikeyCoreSync
import SwiftUI

struct InventoryView: View {
    let environment: AppEnvironment

    @State private var items: [InventoryItem] = []
    @State private var lastUpdatedAt: Date?
    @State private var isPulling = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    InventoryLookupView(environment: environment)
                } label: {
                    Label("Scan Barcode", systemImage: "barcode.viewfinder")
                }
                .accessibilityIdentifier("inventory.scanBarcodeLink")

                NavigationLink {
                    POBuilderView(environment: environment)
                } label: {
                    Label("PO Draft", systemImage: "doc.plaintext")
                }
                .accessibilityIdentifier("inventory.poDraftLink")

                NavigationLink {
                    PurchaseOrdersView(environment: environment)
                } label: {
                    Label("Purchase Orders", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("inventory.purchaseOrdersLink")
            }

            if items.isEmpty {
                Text("No inventory has been pulled yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inventory.emptyState")
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.displayPartNumber)
                                .font(.headline)
                            Spacer()
                            Text("QOH \(item.normalizedQuantityOnHand.formatted(.number.precision(.fractionLength(0...2))))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.description)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
            }

            if let lastUpdatedAt {
                Text("Last updated: \(lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("inventory.lastUpdated")
            }
        }
        .navigationTitle("Inventory")
        .accessibilityIdentifier("inventory.list")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isPulling ? "Pulling…" : "Pull") {
                    Task { await pullInventoryNow() }
                }
                .disabled(isPulling)
                .accessibilityIdentifier("inventory.pullButton")
            }
        }
        .task {
            await reloadFromStore()
        }
    }

    @MainActor
    private func pullInventoryNow() async {
        guard !isPulling else { return }
        isPulling = true
        defer { isPulling = false }

        let operation = SyncOperation(
            id: UUID(),
            type: .syncInventory,
            payloadFingerprint: "inventory.pull.manual",
            status: .pending,
            retryCount: 0,
            createdAt: environment.dateProvider.now
        )
        _ = await environment.syncOperationQueue.enqueue(operation)
        await environment.syncEngine.runOnce()
        await reloadFromStore()
    }

    @MainActor
    private func reloadFromStore() async {
        items = await environment.inventoryStore.allItems()
        lastUpdatedAt = await environment.inventoryStore.lastUpdatedAt()
    }
}
