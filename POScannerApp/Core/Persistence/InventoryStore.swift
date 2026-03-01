//
//  InventoryStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

protocol InventoryStoring: Sendable {
    func allItems() async -> [InventoryItem]
    func replaceAll(_ items: [InventoryItem], at date: Date) async
    func lastUpdatedAt() async -> Date?
}

actor InventoryStore: InventoryStoring {
    private struct PersistedState: Codable {
        var items: [InventoryItem]
        var lastUpdatedAt: Date?
    }

    private let fileURL: URL?
    private var hasLoadedState = false
    private var items: [InventoryItem] = []
    private var syncedAt: Date?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func allItems() async -> [InventoryItem] {
        loadStateIfNeeded()
        return items
    }

    func replaceAll(_ items: [InventoryItem], at date: Date) async {
        loadStateIfNeeded()
        self.items = items.sorted(by: Self.sortInventoryItems)
        syncedAt = date
        persistStateIfNeeded()
    }

    func lastUpdatedAt() async -> Date? {
        loadStateIfNeeded()
        return syncedAt
    }

    private func loadStateIfNeeded() {
        guard !hasLoadedState else { return }
        hasLoadedState = true

        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }

        items = decoded.items.sorted(by: Self.sortInventoryItems)
        syncedAt = decoded.lastUpdatedAt
    }

    private func persistStateIfNeeded() {
        guard let fileURL else { return }

        let state = PersistedState(items: items, lastUpdatedAt: syncedAt)
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep persistence best-effort to avoid blocking app flows.
        }
    }

    private static func sortInventoryItems(lhs: InventoryItem, rhs: InventoryItem) -> Bool {
        if lhs.displayPartNumber.caseInsensitiveCompare(rhs.displayPartNumber) == .orderedSame {
            return lhs.id < rhs.id
        }
        return lhs.displayPartNumber.localizedCaseInsensitiveCompare(rhs.displayPartNumber) == .orderedAscending
    }
}
