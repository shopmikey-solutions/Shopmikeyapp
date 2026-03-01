//
//  PurchaseOrderDraft.swift
//  ShopmikeyCoreModels
//

import Foundation

public enum PurchaseOrderDraftDestination: String, Hashable, Codable, Sendable {
    case restock
}

public struct PurchaseOrderDraft: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var vendorNameHint: String?
    public var destination: PurchaseOrderDraftDestination
    public var lines: [PurchaseOrderDraftLine]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        vendorNameHint: String? = nil,
        destination: PurchaseOrderDraftDestination = .restock,
        lines: [PurchaseOrderDraftLine] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.vendorNameHint = Self.normalizedOptionalString(vendorNameHint)
        self.destination = destination
        self.lines = lines
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
