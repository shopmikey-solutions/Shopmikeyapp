//
//  PurchaseOrderDraftStoreTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct PurchaseOrderDraftStoreTests {
    private struct Harness {
        let fileURL: URL
        let store: PurchaseOrderDraftStore

        init() {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("po_draft_store_tests")
                .appendingPathComponent("\(UUID().uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
            store = PurchaseOrderDraftStore(fileURL: fileURL)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        func makeReloadedStore() -> PurchaseOrderDraftStore {
            PurchaseOrderDraftStore(fileURL: fileURL)
        }
    }

    @Test func addLinePersistsAcrossReload() async {
        let harness = Harness()
        defer { harness.cleanup() }

        let line = PurchaseOrderDraftLine(
            sku: "PAD-001",
            partNumber: "PAD-001",
            description: "Front Brake Pad Set",
            quantity: 2,
            unitCost: 89.99,
            sourceBarcode: "0123456789"
        )
        _ = await harness.store.addLine(line)

        let reloadedStore = harness.makeReloadedStore()
        let draft = await reloadedStore.loadActiveDraft()

        #expect(draft?.lines.count == 1)
        #expect(draft?.lines.first?.description == "Front Brake Pad Set")
        #expect(draft?.lines.first?.sku == "PAD-001")
    }

    @Test func updateLineAndVendorHintPersist() async {
        let harness = Harness()
        defer { harness.cleanup() }

        let line = PurchaseOrderDraftLine(
            description: "Oil Filter",
            quantity: 1,
            unitCost: 12.5
        )
        let draft = await harness.store.addLine(line)

        _ = await harness.store.updateLine(id: line.id, quantity: 3, unitCost: 14.25)
        _ = await harness.store.setVendorNameHint("NAPA")

        let reloadedStore = harness.makeReloadedStore()
        let reloaded = await reloadedStore.loadActiveDraft()

        #expect(reloaded?.id == draft.id)
        #expect(reloaded?.vendorNameHint == "NAPA")
        #expect(reloaded?.lines.first?.quantity == 3)
        #expect(reloaded?.lines.first?.unitCost == 14.25)
    }

    @Test func clearDraftRemovesActiveDraft() async {
        let harness = Harness()
        defer { harness.cleanup() }

        _ = await harness.store.addLine(
            PurchaseOrderDraftLine(description: "Shipping", quantity: 1)
        )
        await harness.store.clearActiveDraft()

        #expect(await harness.store.loadActiveDraft() == nil)
    }

    @Test func invalidJSONRecoversToEmptyDraft() async {
        let harness = Harness()
        defer { harness.cleanup() }

        let directory = harness.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not-json".utf8).write(to: harness.fileURL, options: .atomic)

        let reloadedStore = harness.makeReloadedStore()
        #expect(await reloadedStore.loadActiveDraft() == nil)

        _ = await reloadedStore.addLine(PurchaseOrderDraftLine(description: "Recovered item", quantity: 1))
        #expect(await reloadedStore.loadActiveDraft()?.lines.count == 1)
    }
}
