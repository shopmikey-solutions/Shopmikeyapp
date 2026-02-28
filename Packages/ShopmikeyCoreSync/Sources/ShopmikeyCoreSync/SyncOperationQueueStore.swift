//
//  SyncOperationQueueStore.swift
//  POScannerApp
//

import Foundation

public actor SyncOperationQueueStore {
    public static let shared = SyncOperationQueueStore()

    private struct PersistedState: Codable {
        var operations: [SyncOperation]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let maxOperations: Int
    private var operations: [SyncOperation]

    public init(
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
    public func enqueue(_ operation: SyncOperation) -> UUID {
        if let existingIndex = operations.firstIndex(where: {
            $0.type == operation.type
                && $0.payloadFingerprint == operation.payloadFingerprint
                && $0.status != .succeeded
        }) {
            var existing = operations[existingIndex]
            existing.status = .pending
            existing.lastAttemptAt = operation.lastAttemptAt
            existing.nextAttemptAt = nil
            existing.lastErrorCode = nil
            operations[existingIndex] = existing
            persist()
            return existing.id
        }

        operations.append(operation)
        trimIfNeeded()
        persist()
        return operation.id
    }

    public func markInProgress(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .inProgress
        operations[index].lastAttemptAt = Date()
        operations[index].nextAttemptAt = nil
        persist()
    }

    public func markSucceeded(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .succeeded
        operations[index].lastAttemptAt = Date()
        operations[index].nextAttemptAt = nil
        operations[index].lastErrorCode = nil
        persist()
    }

    public func markFailed(id: UUID) {
        markFailed(id: id, errorCode: nil, nextAttemptAt: nil)
    }

    public func markFailed(id: UUID, errorCode: String?, nextAttemptAt: Date?) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .failed
        operations[index].lastAttemptAt = Date()
        operations[index].nextAttemptAt = nextAttemptAt
        operations[index].lastErrorCode = sanitizedErrorCode(errorCode)
        persist()
    }

    public func incrementRetry(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].retryCount += 1
        operations[index].lastAttemptAt = Date()
        persist()
    }

    public func markPendingForRetry(id: UUID, nextAttemptAt: Date, errorCode: String?) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].status = .pending
        operations[index].nextAttemptAt = nextAttemptAt
        operations[index].lastErrorCode = sanitizedErrorCode(errorCode)
        persist()
    }

    public func pendingOperations() -> [SyncOperation] {
        operations.filter { $0.status == .pending }
    }

    public func readyOperations(asOf date: Date) -> [SyncOperation] {
        operations
            .filter { operation in
                let due = operation.nextAttemptAt.map { $0 <= date } ?? true
                return due && (operation.status == .pending || operation.status == .failed)
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    public func allOperations() -> [SyncOperation] {
        operations
    }

    public func operation(id: UUID) -> SyncOperation? {
        operations.first(where: { $0.id == id })
    }

    public func remove(id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations.remove(at: index)
        persist()
    }

    public func clear() {
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

    private func sanitizedErrorCode(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(120))
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

    public static func defaultFileURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("POScannerApp", isDirectory: true)
            .appendingPathComponent("sync_operation_queue.json", isDirectory: false)
    }
}
