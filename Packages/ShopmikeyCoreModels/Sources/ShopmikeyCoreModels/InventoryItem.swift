//
//  InventoryItem.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct InventoryItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var sku: String
    public var partNumber: String
    public var description: String
    public var price: Decimal
    public var quantityOnHand: Double
    public var vendorId: String?
    public var lastUpdated: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case publicID = "public_id"
        case publicId
        case sku
        case partNumber = "part_number"
        case partNumberAlt = "partNumber"
        case description
        case name
        case price
        case unitPrice = "unit_price"
        case unitPriceAlt = "unitPrice"
        case quantityOnHand = "quantity_on_hand"
        case quantityOnHandAlt = "quantityOnHand"
        case quantity
        case vendorId = "vendor_id"
        case vendorIdAlt = "vendorId"
        case updatedAt = "updated_at"
        case updatedAtAlt = "updatedAt"
    }

    public init(
        id: String,
        sku: String = "",
        partNumber: String = "",
        description: String,
        price: Decimal = .zero,
        quantityOnHand: Double = 0,
        vendorId: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.id = id
        self.sku = sku
        self.partNumber = partNumber
        self.description = description
        self.price = max(0, price)
        self.quantityOnHand = quantityOnHand.isFinite ? quantityOnHand : 0
        self.vendorId = vendorId
        self.lastUpdated = lastUpdated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func decodeString(for keys: [CodingKeys]) -> String? {
            for key in keys {
                if let value = try? container.decodeIfPresent(String.self, forKey: key),
                   let normalized = Self.normalizedString(value) {
                    return normalized
                }
            }
            return nil
        }

        func decodeDecimal(for keys: [CodingKeys]) -> Decimal? {
            for key in keys {
                if let value = try? container.decodeIfPresent(Decimal.self, forKey: key) {
                    return value
                }
                if let value = try? container.decodeIfPresent(Double.self, forKey: key),
                   value.isFinite {
                    return Decimal(value)
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: key),
                   let decimal = Decimal(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return decimal
                }
            }
            return nil
        }

        func decodeDouble(for keys: [CodingKeys]) -> Double? {
            for key in keys {
                if let value = try? container.decodeIfPresent(Double.self, forKey: key),
                   value.isFinite {
                    return value
                }
                if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return Double(value)
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: key),
                   let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                   number.isFinite {
                    return number
                }
            }
            return nil
        }

        func decodeDate(for keys: [CodingKeys]) -> Date? {
            for key in keys {
                if let value = try? container.decodeIfPresent(Date.self, forKey: key) {
                    return value
                }
                if let raw = try? container.decodeIfPresent(String.self, forKey: key),
                   let normalized = Self.normalizedString(raw) {
                    if let isoDate = Self.iso8601Formatter.date(from: normalized) {
                        return isoDate
                    }
                    if let fractionalDate = Self.iso8601FractionalFormatter.date(from: normalized) {
                        return fractionalDate
                    }
                }
            }
            return nil
        }

        id = decodeString(for: [.id, .publicID, .publicId]) ?? UUID().uuidString
        sku = decodeString(for: [.sku]) ?? ""
        partNumber = decodeString(for: [.partNumber, .partNumberAlt]) ?? ""
        description = decodeString(for: [.description, .name]) ?? ""
        price = max(0, decodeDecimal(for: [.price, .unitPrice, .unitPriceAlt]) ?? .zero)
        quantityOnHand = decodeDouble(for: [.quantityOnHand, .quantityOnHandAlt, .quantity]) ?? 0
        vendorId = decodeString(for: [.vendorId, .vendorIdAlt])
        lastUpdated = decodeDate(for: [.updatedAt, .updatedAtAlt])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sku, forKey: .sku)
        try container.encode(partNumber, forKey: .partNumber)
        try container.encode(description, forKey: .description)
        try container.encode(price, forKey: .price)
        try container.encode(quantityOnHand, forKey: .quantityOnHand)
        try container.encodeIfPresent(vendorId, forKey: .vendorId)
        try container.encodeIfPresent(lastUpdated, forKey: .updatedAt)
    }

    public var displayPartNumber: String {
        if let normalized = Self.normalizedString(partNumber) {
            return normalized
        }
        if let normalized = Self.normalizedString(sku) {
            return normalized
        }
        return "Unspecified"
    }

    public var normalizedQuantityOnHand: Double {
        quantityOnHand.isFinite ? quantityOnHand : 0
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
