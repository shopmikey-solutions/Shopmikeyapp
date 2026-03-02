//
//  SubmissionHealthViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import ShopmikeyCoreSync

@MainActor
final class SubmissionHealthViewModel: ObservableObject {
    struct OperationRow: Identifiable, Equatable {
        let id: UUID
        let safeAccessibilityID: String
        let title: String
        let subtitle: String
        let metadata: String
        let diagnostic: String?

        var visibleTextBlob: String {
            [title, subtitle, metadata, diagnostic]
                .compactMap { $0 }
                .joined(separator: " | ")
        }
    }

    @Published private(set) var pendingRows: [OperationRow] = []
    @Published private(set) var retryingRows: [OperationRow] = []
    @Published private(set) var inProgressRows: [OperationRow] = []
    @Published private(set) var failedRows: [OperationRow] = []
    @Published private(set) var lastRefreshedAt: Date?

    private let fetchOperations: @Sendable () async -> [SyncOperation]

    init(syncOperationQueue: SyncOperationQueueStore) {
        self.fetchOperations = { await syncOperationQueue.allOperations() }
    }

    init(fetchOperations: @escaping @Sendable () async -> [SyncOperation]) {
        self.fetchOperations = fetchOperations
    }

    func refresh() async {
        let operations = await fetchOperations()
        let grouped = Self.groupAndSort(operations: operations)

        pendingRows = grouped.pending.map(Self.makeRow(from:))
        retryingRows = grouped.retrying.map(Self.makeRow(from:))
        inProgressRows = grouped.inProgress.map(Self.makeRow(from:))
        failedRows = grouped.failed.map(Self.makeRow(from:))
        lastRefreshedAt = Date()
    }

    private struct GroupedOperations {
        var pending: [SyncOperation]
        var retrying: [SyncOperation]
        var inProgress: [SyncOperation]
        var failed: [SyncOperation]
    }

    private static func groupAndSort(operations: [SyncOperation]) -> GroupedOperations {
        var pending: [SyncOperation] = []
        var retrying: [SyncOperation] = []
        var inProgress: [SyncOperation] = []
        var failed: [SyncOperation] = []

        for operation in operations {
            switch operation.status {
            case .pending:
                if operation.retryCount > 0 || operation.nextAttemptAt != nil {
                    retrying.append(operation)
                } else {
                    pending.append(operation)
                }
            case .inProgress:
                inProgress.append(operation)
            case .failed:
                failed.append(operation)
            case .succeeded:
                continue
            }
        }

        pending.sort {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }

        retrying.sort {
            let lhsNext = $0.nextAttemptAt
            let rhsNext = $1.nextAttemptAt
            switch (lhsNext, rhsNext) {
            case let (lhs?, rhs?):
                if lhs == rhs {
                    if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                    return $0.createdAt < $1.createdAt
                }
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt < $1.createdAt
            }
        }

        inProgress.sort {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }

        failed.sort {
            let lhsDate = $0.lastAttemptAt ?? $0.createdAt
            let rhsDate = $1.lastAttemptAt ?? $1.createdAt
            if lhsDate == rhsDate { return $0.id.uuidString < $1.id.uuidString }
            return lhsDate > rhsDate
        }

        return GroupedOperations(
            pending: pending,
            retrying: retrying,
            inProgress: inProgress,
            failed: failed
        )
    }

    static func makeRow(from operation: SyncOperation) -> OperationRow {
        let shortID = String(operation.id.uuidString.prefix(8)).uppercased()
        let subtitle = "Operation ID \(shortID)"
        var metadataParts: [String] = ["Retries \(operation.retryCount)"]

        if let nextAttemptAt = operation.nextAttemptAt {
            metadataParts.append("Next \(nextAttemptAt.formatted(date: .omitted, time: .shortened))")
        }

        if let lastAttemptAt = operation.lastAttemptAt {
            metadataParts.append("Last \(lastAttemptAt.formatted(date: .omitted, time: .shortened))")
        }

        return OperationRow(
            id: operation.id,
            safeAccessibilityID: sanitizedAccessibilityID(for: operation.id.uuidString),
            title: operationTypeTitle(operation.type),
            subtitle: subtitle,
            metadata: metadataParts.joined(separator: " • "),
            diagnostic: operation.lastErrorCode.flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : "Diagnostic \($0)"
            }
        )
    }

    static func sanitizedAccessibilityID(for rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalarView = rawValue.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let sanitized = String(scalarView)
        if sanitized.count <= 32 {
            return sanitized
        }
        return String(sanitized.prefix(32))
    }

    private static func operationTypeTitle(_ type: OperationType) -> String {
        switch type {
        case .submitPurchaseOrder:
            return "Submit Purchase Order"
        case .syncInventory:
            return "Sync Inventory"
        case .syncVendor:
            return "Sync Vendor"
        case .addTicketLineItem:
            return "Add Ticket Line Item"
        case .receivePurchaseOrderLineItem:
            return "Receive PO Line Item"
        }
    }
}
