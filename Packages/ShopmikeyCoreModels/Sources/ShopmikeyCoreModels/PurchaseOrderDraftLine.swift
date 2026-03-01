//
//  PurchaseOrderDraftLine.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct PurchaseOrderDraftLine: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var sku: String?
    public var partNumber: String?
    public var description: String
    public var quantity: Decimal
    public var unitCost: Decimal?
    public var sourceBarcode: String?

    public init(
        id: UUID = UUID(),
        sku: String? = nil,
        partNumber: String? = nil,
        description: String,
        quantity: Decimal = 1,
        unitCost: Decimal? = nil,
        sourceBarcode: String? = nil
    ) {
        self.id = id
        self.sku = Self.normalizedOptionalString(sku)
        self.partNumber = Self.normalizedOptionalString(partNumber)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.quantity = max(1, quantity)
        if let unitCost {
            self.unitCost = max(0, unitCost)
        } else {
            self.unitCost = nil
        }
        self.sourceBarcode = Self.normalizedOptionalString(sourceBarcode)
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
