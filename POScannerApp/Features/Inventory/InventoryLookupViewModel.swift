//
//  InventoryLookupViewModel.swift
//  POScannerApp
//

import Combine
import Foundation
import ShopmikeyCoreModels

@MainActor
final class InventoryLookupViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case matchFound(InventoryItem)
        case noMatch
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var scannedCode: String?

    private let inventoryStore: InventoryStoring

    init(inventoryStore: InventoryStoring) {
        self.inventoryStore = inventoryStore
    }

    func startScanning() {
        state = .scanning
    }

    func setScannerUnavailable() {
        state = .error("Scanner unavailable on this device.")
    }

    func reset() {
        scannedCode = nil
        state = .idle
    }

    func lookup(scannedCode rawCode: String?) async {
        let exactScannedCode = Self.trimmed(rawCode)
        self.scannedCode = exactScannedCode

        guard let exactScannedCode else {
            state = .idle
            return
        }

        let items = await inventoryStore.allItems()

        if let exactSkuMatch = items.first(where: {
            Self.trimmed($0.sku) == exactScannedCode
        }) {
            state = .matchFound(exactSkuMatch)
            return
        }

        if let exactPartNumberMatch = items.first(where: {
            Self.trimmed($0.partNumber) == exactScannedCode
        }) {
            state = .matchFound(exactPartNumberMatch)
            return
        }

        guard let normalizedScannedCode = Self.normalized(exactScannedCode) else {
            state = .noMatch
            return
        }

        if let normalizedMatch = items.first(where: { item in
            Self.normalized(item.sku) == normalizedScannedCode ||
            Self.normalized(item.partNumber) == normalizedScannedCode
        }) {
            state = .matchFound(normalizedMatch)
            return
        }

        state = .noMatch
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = trimmed(value) else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
