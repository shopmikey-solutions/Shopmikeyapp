//
//  InventoryStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

protocol InventoryStoring: Sendable {
    func allItems() async -> [InventoryItem]
    func lookupItem(scannedCode: String) async -> InventoryItem?
    func replaceAll(_ items: [InventoryItem], at date: Date) async
    func incrementOnHand(
        sku: String?,
        partNumber: String?,
        description: String?,
        by quantity: Decimal,
        at date: Date
    ) async -> Bool
    func lastRefreshedAt() async -> Date?
    func isStale(now: Date, threshold: TimeInterval) async -> Bool
    func lastUpdatedAt() async -> Date?
}

extension InventoryStoring {
    func lookupItem(scannedCode: String) async -> InventoryItem? {
        let trimmed = scannedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let all = await allItems()
        if let skuMatch = all.first(where: {
            $0.sku.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
        }) {
            return skuMatch
        }
        return all.first(where: {
            $0.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
        })
    }

    func lastRefreshedAt() async -> Date? {
        await lastUpdatedAt()
    }

    func isStale(now: Date, threshold: TimeInterval) async -> Bool {
        guard let lastRefreshedAt = await lastRefreshedAt() else { return true }
        return now.timeIntervalSince(lastRefreshedAt) > threshold
    }
}

actor InventoryStore: InventoryStoring {
    private struct PersistedState: Codable {
        var items: [InventoryItem]
        var lastRefreshedAt: Date?
        var lastUpdatedAt: Date?
    }

    private struct PersistedAppliedReceiveKeys: Codable {
        var keys: [String]
    }

    private static let receiveKeyPrefix = "__smk_receive_key__="
    private static let appliedReceiveKeysFilename = "inventory_receive_applied.json"
    private static let maxAppliedReceiveKeys = 2_000

    private let fileURL: URL?
    private let appliedReceiveKeysFileURL: URL?
    private var hasLoadedState = false
    private var items: [InventoryItem] = []
    private var syncedAt: Date?
    private var skuIndex: [String: Int] = [:]
    private var partNumberIndex: [String: Int] = [:]
    private var descriptionFallbackIndex: [String: Int] = [:]
    private var appliedReceiveKeys: [String] = []
    private var appliedReceiveKeySet: Set<String> = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL {
            self.appliedReceiveKeysFileURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(Self.appliedReceiveKeysFilename, isDirectory: false)
        } else {
            self.appliedReceiveKeysFileURL = nil
        }
    }

    func allItems() async -> [InventoryItem] {
        loadStateIfNeeded()
        return items
    }

    func lookupItem(scannedCode: String) async -> InventoryItem? {
        loadStateIfNeeded()
        guard let normalizedCode = normalizedComparable(scannedCode) else { return nil }

        if let skuMatch = skuIndex[normalizedCode] {
            return items[safe: skuMatch]
        }

        if let partMatch = partNumberIndex[normalizedCode] {
            return items[safe: partMatch]
        }

        if let descriptionMatch = descriptionFallbackIndex[normalizedCode] {
            return items[safe: descriptionMatch]
        }

        return nil
    }

    func replaceAll(_ items: [InventoryItem], at date: Date) async {
        loadStateIfNeeded()
        self.items = items.sorted(by: Self.sortInventoryItems)
        syncedAt = date
        rebuildIndexes()
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

        let receiveExtraction = extractReceiveKey(from: description)
        if let receiveKey = receiveExtraction.receiveKey,
           appliedReceiveKeySet.contains(receiveKey) {
            return true
        }

        guard let index = matchingIndex(
            sku: normalizedComparable(sku),
            partNumber: normalizedComparable(partNumber),
            description: normalizedComparable(receiveExtraction.cleanDescription)
        ) else {
            if let receiveKey = receiveExtraction.receiveKey {
                recordAppliedReceiveKey(receiveKey)
            }
            return false
        }

        var matched = items[index]
        matched.quantityOnHand = max(0, matched.quantityOnHand + delta)
        matched.lastUpdated = date
        items[index] = matched
        items.sort(by: Self.sortInventoryItems)
        syncedAt = date
        rebuildIndexes()
        persistStateIfNeeded()
        if let receiveKey = receiveExtraction.receiveKey {
            recordAppliedReceiveKey(receiveKey)
        }
        return true
    }

    func lastRefreshedAt() async -> Date? {
        loadStateIfNeeded()
        return syncedAt
    }

    func isStale(now: Date, threshold: TimeInterval) async -> Bool {
        loadStateIfNeeded()
        guard let syncedAt else { return true }
        return now.timeIntervalSince(syncedAt) > threshold
    }

    func lastUpdatedAt() async -> Date? {
        loadStateIfNeeded()
        return syncedAt
    }

    func debugIndexCounts() async -> (sku: Int, partNumber: Int, descriptionFallback: Int) {
        loadStateIfNeeded()
        return (skuIndex.count, partNumberIndex.count, descriptionFallbackIndex.count)
    }

    private func loadStateIfNeeded() {
        guard !hasLoadedState else { return }
        hasLoadedState = true
        loadAppliedReceiveKeys()

        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }

        items = decoded.items.sorted(by: Self.sortInventoryItems)
        syncedAt = decoded.lastRefreshedAt ?? decoded.lastUpdatedAt
        rebuildIndexes()
    }

    private func persistStateIfNeeded() {
        guard let fileURL else { return }

        let state = PersistedState(
            items: items,
            lastRefreshedAt: syncedAt,
            lastUpdatedAt: syncedAt
        )
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep persistence best-effort to avoid blocking app flows.
        }
    }

    private func loadAppliedReceiveKeys() {
        guard let appliedReceiveKeysFileURL,
              let data = try? Data(contentsOf: appliedReceiveKeysFileURL),
              let decoded = try? JSONDecoder().decode(PersistedAppliedReceiveKeys.self, from: data) else {
            return
        }

        appliedReceiveKeys = decoded.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if appliedReceiveKeys.count > Self.maxAppliedReceiveKeys {
            appliedReceiveKeys = Array(appliedReceiveKeys.suffix(Self.maxAppliedReceiveKeys))
        }
        appliedReceiveKeySet = Set(appliedReceiveKeys)
    }

    private func persistAppliedReceiveKeysIfNeeded() {
        guard let appliedReceiveKeysFileURL else { return }

        do {
            let directoryURL = appliedReceiveKeysFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            let state = PersistedAppliedReceiveKeys(keys: appliedReceiveKeys)
            let data = try JSONEncoder().encode(state)
            try data.write(to: appliedReceiveKeysFileURL, options: .atomic)
        } catch {
            // Keep persistence best-effort to avoid blocking app flows.
        }
    }

    private func recordAppliedReceiveKey(_ key: String) {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !appliedReceiveKeySet.contains(normalized) else { return }

        appliedReceiveKeySet.insert(normalized)
        appliedReceiveKeys.append(normalized)
        if appliedReceiveKeys.count > Self.maxAppliedReceiveKeys {
            let overflow = appliedReceiveKeys.count - Self.maxAppliedReceiveKeys
            let removed = appliedReceiveKeys.prefix(overflow)
            appliedReceiveKeys.removeFirst(overflow)
            for key in removed {
                appliedReceiveKeySet.remove(key)
            }
            for key in appliedReceiveKeys {
                appliedReceiveKeySet.insert(key)
            }
        }
        persistAppliedReceiveKeysIfNeeded()
    }

    private func extractReceiveKey(from description: String?) -> (receiveKey: String?, cleanDescription: String?) {
        guard let description else { return (nil, nil) }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.receiveKeyPrefix) else {
            return (nil, description)
        }

        let payload = String(trimmed.dropFirst(Self.receiveKeyPrefix.count))
        let components = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let encodedReceiveKey = components.first.map(String.init)
        let cleanDescription = components.count > 1 ? String(components[1]) : nil

        return (
            encodedReceiveKey?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
            cleanDescription
        )
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
           let skuMatch = skuIndex[sku] {
            return skuMatch
        }

        if let partNumber, !partNumber.isEmpty,
           let partMatch = partNumberIndex[partNumber] {
            return partMatch
        }

        guard (sku == nil || sku?.isEmpty == true),
              (partNumber == nil || partNumber?.isEmpty == true),
              let description,
              !description.isEmpty else {
            return nil
        }

        return descriptionFallbackIndex[description]
    }

    private func rebuildIndexes() {
        var newSKUIndex: [String: Int] = [:]
        var newPartNumberIndex: [String: Int] = [:]
        var newDescriptionFallbackIndex: [String: Int] = [:]

        newSKUIndex.reserveCapacity(items.count)
        newPartNumberIndex.reserveCapacity(items.count)
        newDescriptionFallbackIndex.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            if let sku = normalizedComparable(item.sku), newSKUIndex[sku] == nil {
                newSKUIndex[sku] = index
            }
            if let partNumber = normalizedComparable(item.partNumber), newPartNumberIndex[partNumber] == nil {
                newPartNumberIndex[partNumber] = index
            }
            if normalizedComparable(item.sku) == nil,
               normalizedComparable(item.partNumber) == nil,
               let description = normalizedComparable(item.description),
               newDescriptionFallbackIndex[description] == nil {
                newDescriptionFallbackIndex[description] = index
            }
        }

        skuIndex = newSKUIndex
        partNumberIndex = newPartNumberIndex
        descriptionFallbackIndex = newDescriptionFallbackIndex
    }

    private func normalizedComparable(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
