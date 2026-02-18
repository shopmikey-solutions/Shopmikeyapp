//
//  ReviewDraftStore.swift
//  POScannerApp
//

import Foundation

actor ReviewDraftStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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

    func list() -> [ReviewDraftSnapshot] {
        readAll().sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) -> ReviewDraftSnapshot? {
        readAll().first { $0.id == id }
    }

    func upsert(_ snapshot: ReviewDraftSnapshot) throws {
        var drafts = readAll()
        if let index = drafts.firstIndex(where: { $0.id == snapshot.id }) {
            drafts[index] = snapshot
        } else {
            drafts.append(snapshot)
        }
        try writeAll(drafts)
    }

    func delete(id: UUID) throws {
        let filtered = readAll().filter { $0.id != id }
        try writeAll(filtered)
    }

    private func readAll() -> [ReviewDraftSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard !data.isEmpty else { return [] }
        return (try? decoder.decode([ReviewDraftSnapshot].self, from: data)) ?? []
    }

    private func writeAll(_ drafts: [ReviewDraftSnapshot]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(drafts)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("POScannerApp", isDirectory: true)
            .appendingPathComponent("review_drafts.json", isDirectory: false)
    }
}
