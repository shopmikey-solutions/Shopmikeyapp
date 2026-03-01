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
        persistStateIfNeeded()
        if let receiveKey = receiveExtraction.receiveKey {
            recordAppliedReceiveKey(receiveKey)
        }
        return true
    }

    func lastUpdatedAt() async -> Date? {
        loadStateIfNeeded()
        return syncedAt
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
