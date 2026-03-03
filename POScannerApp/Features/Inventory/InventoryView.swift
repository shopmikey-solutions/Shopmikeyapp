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
    @State private var isLoading = true

    var body: some View {
        ZStack {
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

                if !isLoading, items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No inventory pulled yet")
                            .font(.subheadline.weight(.semibold))
                        Text("Use Pull to refresh your local inventory cache.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("inventory.emptyState")
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.description)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text(item.displayPartNumber)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("QOH \(item.normalizedQuantityOnHand.formatted(.number.precision(.fractionLength(0...2))))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
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

            if isLoading {
                CenteredLoadingView(label: "Loading inventory…")
                    .accessibilityIdentifier("inventory.loading")
            }
        }
        .navigationTitle("Inventory")
        .accessibilityIdentifier("inventory.list")
        .animation(.easeInOut(duration: 0.2), value: items)
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
        AppHaptics.success()
    }

    @MainActor
    private func reloadFromStore() async {
        items = await environment.inventoryStore.allItems()
        lastUpdatedAt = await environment.inventoryStore.lastUpdatedAt()
        isLoading = false
    }
}
