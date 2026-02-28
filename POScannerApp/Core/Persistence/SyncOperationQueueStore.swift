//
//  SyncOperationQueueStore.swift
//  POScannerApp
//

import Foundation

actor SyncOperationQueueStore {
    static let shared = SyncOperationQueueStore()

    private struct PersistedState: Codable {
        var operations: [SyncOperation]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let maxOperations: Int
    private var operations: [SyncOperation]

    init(
        fileURL: URL = SyncOperationQueueStore.defaultFileURL(),
        fileManager: FileManager = .default,
        maxOperations: Int = 1_000
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.maxOperations = max(1, maxOperations)
        self.operations = []
        self.operations = Self.loadOperations(from: fileURL, fileManager: fileManager)
    }

    @discardableResult
    func enqueue(_ operation: SyncOperation) -> UUID {
        if let existingIndex = operations.firstIndex(where: {
            $0.type == operation.type
                && $0.payloadFingerprint == operation.payloadFingerprint
                && $0.status != .succeeded
        }) {
            var existing = operations[existingIndex]
            existing.status = .pending
            existing.lastAttemptAt = operation.lastAttemptAt
            operations[existingIndex] = existing
            persist()
            return existing.id
        }

        operations.append(operation)
        trimIfNeeded()
        persist()
        return operation.id
    }

    func markInProgress(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .inProgress
        operations[index].lastAttemptAt = Date()
        persist()
    }

    func markSucceeded(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .succeeded
        operations[index].lastAttemptAt = Date()
        persist()
    }

    func markFailed(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .failed
        operations[index].lastAttemptAt = Date()
        persist()
    }

    func incrementRetry(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].retryCount += 1
        operations[index].lastAttemptAt = Date()
        persist()
    }

    func pendingOperations() -> [SyncOperation] {
        operations.filter { $0.status == .pending }
    }

    func allOperations() -> [SyncOperation] {
        operations
    }

    func operation(id: UUID) -> SyncOperation? {
        operations.first(where: { $0.id == id })
    }

    func remove(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations.remove(at: index)
        persist()
    }

    func clear() {
        operations.removeAll(keepingCapacity: false)
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            // Best-effort cleanup.
        }
    }

    private func persist() {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(PersistedState(operations: operations))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Queue persistence is best-effort; app flow should continue even if disk write fails.
        }
    }

    private func trimIfNeeded() {
        guard operations.count > maxOperations else { return }
        operations.removeFirst(operations.count - maxOperations)
    }

    private static func loadOperations(from fileURL: URL, fileManager: FileManager) -> [SyncOperation] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            return state.operations
        } catch {
            return []
        }
    }

    private static func defaultFileURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("POScannerApp", isDirectory: true)
            .appendingPathComponent("sync_operation_queue.json", isDirectory: false)
    }
}
