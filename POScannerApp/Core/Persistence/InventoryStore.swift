//
//  InventoryStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

protocol InventoryStoring: Sendable {
    func allItems() async -> [InventoryItem]
    func replaceAll(_ items: [InventoryItem], at date: Date) async
    func incrementOnHand(
        sku: String?,
        partNumber: String?,
        description: String?,
        by quantity: Decimal,
        at date: Date
    ) async -> Bool
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

    func incrementOnHand(
        sku: String?,
        partNumber: String?,
        description: String?,
        by quantity: Decimal,
        at date: Date
    ) async -> Bool {
        loadStateIfNeeded()

        let delta = max(0, NSDecimalNumber(decimal: quantity).doubleValue)
        guard delta > 0 else { return true }

        guard let index = matchingIndex(
            sku: normalizedComparable(sku),
            partNumber: normalizedComparable(partNumber),
            description: normalizedComparable(description)
        ) else {
            return false
        }

        var matched = items[index]
        matched.quantityOnHand = max(0, matched.quantityOnHand + delta)
        matched.lastUpdated = date
        items[index] = matched
        items.sort(by: Self.sortInventoryItems)
        syncedAt = date
        persistStateIfNeeded()
        return true
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

    private func matchingIndex(
        sku: String?,
        partNumber: String?,
        description: String?
    ) -> Int? {
        if let sku, !sku.isEmpty,
           let skuMatch = items.firstIndex(where: { normalizedComparable($0.sku) == sku }) {
            return skuMatch
        }

        if let partNumber, !partNumber.isEmpty,
           let partMatch = items.firstIndex(where: { normalizedComparable($0.partNumber) == partNumber }) {
            return partMatch
        }

        guard (sku == nil || sku?.isEmpty == true),
              (partNumber == nil || partNumber?.isEmpty == true),
              let description,
              !description.isEmpty else {
            return nil
        }

        return items.firstIndex { item in
            guard normalizedComparable(item.sku) == nil,
                  normalizedComparable(item.partNumber) == nil else {
                return false
            }
            return normalizedComparable(item.description) == description
        }
    }

    private func normalizedComparable(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
