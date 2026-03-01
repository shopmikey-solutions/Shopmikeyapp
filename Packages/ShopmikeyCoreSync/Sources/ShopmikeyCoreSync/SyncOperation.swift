//
//  SyncOperation.swift
//  POScannerApp
//

import Foundation

public enum OperationType: String, Codable, Sendable {
    case submitPurchaseOrder
    case syncInventory
    case syncVendor
    case addTicketLineItem
    case receivePurchaseOrderLineItem
}

public enum OperationStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case succeeded
    case failed
}

public struct SyncOperation: Codable, Identifiable, Sendable {
    public let id: UUID
    public let type: OperationType
    public let payloadFingerprint: String
    public var status: OperationStatus
    public var retryCount: Int
    public let createdAt: Date
    public var lastAttemptAt: Date?
    public var nextAttemptAt: Date?
    public var lastErrorCode: String?

    public init(
        id: UUID,
        type: OperationType,
        payloadFingerprint: String,
        status: OperationStatus,
        retryCount: Int,
        createdAt: Date,
        lastAttemptAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        lastErrorCode: String? = nil
    ) {
        self.id = id
        self.type = type
        self.payloadFingerprint = payloadFingerprint
        self.status = status
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.lastErrorCode = lastErrorCode
    }
}
