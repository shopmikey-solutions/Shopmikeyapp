//
//  SyncOperation.swift
//  POScannerApp
//

import Foundation

enum OperationType: String, Codable {
    case submitPurchaseOrder
    case syncInventory
    case syncVendor
}

enum OperationStatus: String, Codable {
    case pending
    case inProgress
    case succeeded
    case failed
}

struct SyncOperation: Codable, Identifiable {
    let id: UUID
    let type: OperationType
    let payloadFingerprint: String
    var status: OperationStatus
    var retryCount: Int
    let createdAt: Date
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var lastErrorCode: String?
}
