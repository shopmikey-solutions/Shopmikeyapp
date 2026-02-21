//
//  ReviewDraftStore.swift
//  POScannerApp
//

import Foundation

protocol ReviewDraftStoring: Sendable {
    func list() async -> [ReviewDraftSnapshot]
    func load(id: UUID) async -> ReviewDraftSnapshot?
    func upsert(_ snapshot: ReviewDraftSnapshot) async throws
    func delete(id: UUID) async throws
}

actor ReviewDraftStore: ReviewDraftStoring {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxDraftCount: Int = 60
    private let maxDraftFileBytes: Int64 = 5_000_000

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func list() async -> [ReviewDraftSnapshot] {
        readAll().sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) async -> ReviewDraftSnapshot? {
        readAll().first { $0.id == id }
    }

    func upsert(_ snapshot: ReviewDraftSnapshot) async throws {
        var drafts = readAll()
        if let index = drafts.firstIndex(where: { $0.id == snapshot.id }) {
            let existing = drafts[index]
            if existing.state.workflowStateRawValue != nil,
               !existing.workflowState.allowsTransition(to: snapshot.workflowState) {
                return
            }

            var merged = snapshot
            merged.createdAt = min(existing.createdAt, snapshot.createdAt)
            merged.updatedAt = max(existing.updatedAt, snapshot.updatedAt)

            if existing == merged {
                return
            }
            drafts[index] = merged
        } else {
            drafts.append(snapshot)
        }
        try writeAll(pruned(drafts))
        notifyDidChange()
    }

    func delete(id: UUID) async throws {
        let filtered = readAll().filter { $0.id != id }
        try writeAll(filtered)
        notifyDidChange()
    }

    private func readAll() -> [ReviewDraftSnapshot] {
        if shouldResetCorruptedOrOversizedStore() {
            resetStoreFile()
            return []
        }

        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard !data.isEmpty else { return [] }

        guard let decoded = try? decoder.decode([ReviewDraftSnapshot].self, from: data) else {
            resetStoreFile()
            return []
        }

        return pruned(decoded)
    }

    private func writeAll(_ drafts: [ReviewDraftSnapshot]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(drafts)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func pruned(_ drafts: [ReviewDraftSnapshot]) -> [ReviewDraftSnapshot] {
        let ordered = drafts.sorted { $0.updatedAt > $1.updatedAt }
        if ordered.count <= maxDraftCount {
            return ordered
        }
        return Array(ordered.prefix(maxDraftCount))
    }

    private func shouldResetCorruptedOrOversizedStore() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return false
        }

        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return byteCount > maxDraftFileBytes
    }

    private func resetStoreFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: fileURL, options: [.atomic])
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("POScannerApp", isDirectory: true)
            .appendingPathComponent("review_drafts.json", isDirectory: false)
    }

    private func notifyDidChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .reviewDraftStoreDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let reviewDraftStoreDidChange = Notification.Name("POScannerApp.reviewDraftStoreDidChange")
}
