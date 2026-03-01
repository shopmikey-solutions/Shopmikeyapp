//
//  PurchaseOrderDraftStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

protocol PurchaseOrderDraftStoring: Sendable {
    func loadActiveDraft() async -> PurchaseOrderDraft?
    func saveDraft(_ draft: PurchaseOrderDraft) async
    func clearActiveDraft() async
    func addLine(_ line: PurchaseOrderDraftLine) async -> PurchaseOrderDraft
    func updateLine(id: UUID, quantity: Decimal, unitCost: Decimal?) async -> PurchaseOrderDraft?
    func removeLine(id: UUID) async -> PurchaseOrderDraft?
    func setVendorNameHint(_ vendorName: String?) async -> PurchaseOrderDraft?
}

actor PurchaseOrderDraftStore: PurchaseOrderDraftStoring {
    private struct PersistedState: Codable {
        var activeDraft: PurchaseOrderDraft?
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dateProvider: @Sendable () -> Date

    private var hasLoadedState = false
    private var activeDraft: PurchaseOrderDraft?

    init(
        fileURL: URL? = nil,
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.dateProvider = dateProvider

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadActiveDraft() async -> PurchaseOrderDraft? {
        loadStateIfNeeded()
        return activeDraft
    }

    func saveDraft(_ draft: PurchaseOrderDraft) async {
        loadStateIfNeeded()

        var nextDraft = draft
        if let existing = activeDraft,
           existing.id == draft.id {
            nextDraft.createdAt = min(existing.createdAt, draft.createdAt)
        }
        nextDraft.updatedAt = dateProvider()
        nextDraft.vendorNameHint = normalizedOptionalString(nextDraft.vendorNameHint)

        activeDraft = nextDraft
        persistStateIfNeeded()
    }

    func clearActiveDraft() async {
        loadStateIfNeeded()
        activeDraft = nil
        persistStateIfNeeded()
    }

    func addLine(_ line: PurchaseOrderDraftLine) async -> PurchaseOrderDraft {
        loadStateIfNeeded()

        let now = dateProvider()
        var draft = activeDraft ?? PurchaseOrderDraft(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            destination: .restock,
            lines: []
        )
        draft.lines.append(line)
        draft.updatedAt = now

        activeDraft = draft
        persistStateIfNeeded()
        return draft
    }

    func updateLine(id: UUID, quantity: Decimal, unitCost: Decimal?) async -> PurchaseOrderDraft? {
        loadStateIfNeeded()
        guard var draft = activeDraft,
              let index = draft.lines.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        draft.lines[index].quantity = max(1, quantity)
        if let unitCost {
            draft.lines[index].unitCost = max(0, unitCost)
        } else {
            draft.lines[index].unitCost = nil
        }
        draft.updatedAt = dateProvider()

        activeDraft = draft
        persistStateIfNeeded()
        return draft
    }

    func removeLine(id: UUID) async -> PurchaseOrderDraft? {
        loadStateIfNeeded()
        guard var draft = activeDraft else { return nil }

        let originalCount = draft.lines.count
        draft.lines.removeAll { $0.id == id }
        guard draft.lines.count != originalCount else { return draft }

        draft.updatedAt = dateProvider()
        activeDraft = draft
        persistStateIfNeeded()
        return draft
    }

    func setVendorNameHint(_ vendorName: String?) async -> PurchaseOrderDraft? {
        loadStateIfNeeded()
        guard var draft = activeDraft else { return nil }

        draft.vendorNameHint = normalizedOptionalString(vendorName)
        draft.updatedAt = dateProvider()
        activeDraft = draft
        persistStateIfNeeded()
        return draft
    }

    private func loadStateIfNeeded() {
        guard !hasLoadedState else { return }
        hasLoadedState = true

        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return
        }

        guard let decoded = try? decoder.decode(PersistedState.self, from: data) else {
            activeDraft = nil
            resetStoreFile()
            return
        }

        activeDraft = decoded.activeDraft
    }

    private func persistStateIfNeeded() {
        let persisted = PersistedState(activeDraft: activeDraft)

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(persisted)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Keep draft persistence best-effort to avoid blocking interaction.
        }
    }

    private func resetStoreFile() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(PersistedState(activeDraft: nil))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Recovery is best-effort.
        }
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("POScannerApp", isDirectory: true)
            .appendingPathComponent("purchase_order_draft.json", isDirectory: false)
    }
}
