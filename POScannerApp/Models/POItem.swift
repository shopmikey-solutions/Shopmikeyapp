//
//  POItem.swift
//  POScannerApp
//

import Foundation

enum POItemKind: String, Codable, CaseIterable, Hashable {
    case part
    case tire
    case fee
    case unknown

    var displayName: String {
        switch self {
        case .part:
            return "Part"
        case .tire:
            return "Tire"
        case .fee:
            return "Fee"
        case .unknown:
            return "Auto"
        }
    }

    static func from(rawValueOrAlias value: String?) -> POItemKind {
        guard let value else { return .unknown }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "part", "parts":
            return .part
        case "tire", "tyre", "tires", "tyres":
            return .tire
        case "fee", "fees", "freight", "shipping", "tax":
            return .fee
        default:
            return .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try? container.decode(String.self)
        self = POItemKind.from(rawValueOrAlias: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Editable line item used in parsing, review UI, and submission mapping.
struct POItem: Identifiable, Hashable, Codable, Equatable {
    var id: UUID = UUID()

    var sku: String = ""
    var description: String
    var quantity: Double = 1
    var unitCost: Decimal = 0
    var isTaxable: Bool = true

    var partNumber: String?
    var confidence: Double = 0.5
    var kind: POItemKind = .unknown
    var kindConfidence: Double = 0
    var kindReasons: [String] = []

    private enum CodingKeys: String, CodingKey {
        case id
        case sku
        case description
        case name
        case quantity
        case unitCost
        case cost
        case costCents
        case unitPrice
        case isTaxable
        case partNumber
        case confidence
        case kind
        case kindConfidence
        case kindReasons
    }

    init(
        id: UUID = UUID(),
        description: String,
        sku: String = "",
        quantity: Double = 1,
        unitCost: Decimal = 0,
        isTaxable: Bool = true,
        partNumber: String? = nil,
        confidence: Double = 0.5,
        kind: POItemKind = .unknown,
        kindConfidence: Double = 0,
        kindReasons: [String] = []
    ) {
        self.id = id
        self.sku = sku
        self.description = description
        self.quantity = Self.sanitizedQuantity(quantity)
        self.unitCost = max(0, unitCost)
        self.isTaxable = isTaxable
        self.partNumber = partNumber
        self.confidence = Self.sanitizedUnitInterval(confidence, fallback: 0.5)
        self.kind = kind
        self.kindConfidence = Self.sanitizedUnitInterval(kindConfidence, fallback: 0)
        self.kindReasons = kindReasons
    }

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int,
        cost: Double,
        partNumber: String? = nil,
        costCents: Int? = nil,
        confidence: Double = 0.5,
        sku: String = "",
        isTaxable: Bool = true,
        kind: POItemKind = .unknown,
        kindConfidence: Double = 0,
        kindReasons: [String] = []
    ) {
        self.id = id
        self.sku = sku
        self.description = name
        self.quantity = Double(max(1, quantity))
        if let costCents {
            self.unitCost = Decimal(costCents) / 100
        } else {
            let safeCost = cost.isFinite ? cost : 0
            self.unitCost = max(0, Decimal(safeCost))
        }
        self.isTaxable = isTaxable
        self.partNumber = partNumber
        self.confidence = Self.sanitizedUnitInterval(confidence, fallback: 0.5)
        self.kind = kind
        self.kindConfidence = Self.sanitizedUnitInterval(kindConfidence, fallback: 0)
        self.kindReasons = kindReasons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func decodeDecimal(_ key: CodingKeys) throws -> Decimal? {
            if let value = try container.decodeIfPresent(Decimal.self, forKey: key) {
                return value
            }
            if let value = try container.decodeIfPresent(Double.self, forKey: key) {
                guard value.isFinite else { return nil }
                return Decimal(value)
            }
            if let value = try container.decodeIfPresent(Int.self, forKey: key) {
                return Decimal(value)
            }
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let decimal = Decimal(string: trimmed) {
                    return decimal
                }
            }
            return nil
        }

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sku = try container.decodeIfPresent(String.self, forKey: .sku) ?? ""
        if let decodedDescription = try container.decodeIfPresent(String.self, forKey: .description) {
            description = decodedDescription
        } else if let legacyName = try container.decodeIfPresent(String.self, forKey: .name) {
            description = legacyName
        } else {
            description = ""
        }

        if let decodedQuantity = try container.decodeIfPresent(Double.self, forKey: .quantity) {
            quantity = Self.sanitizedQuantity(decodedQuantity)
        } else if let decodedQuantityInt = try container.decodeIfPresent(Int.self, forKey: .quantity) {
            quantity = Double(max(1, decodedQuantityInt))
        } else {
            quantity = 1
        }

        if let legacyCostCents = try container.decodeIfPresent(Int.self, forKey: .costCents) {
            unitCost = max(0, Decimal(legacyCostCents) / 100)
        } else {
            let decodedUnitCost =
                try decodeDecimal(.unitCost)
                ?? decodeDecimal(.cost)
                ?? decodeDecimal(.unitPrice)
                ?? .zero
            unitCost = max(0, decodedUnitCost)
        }

        isTaxable = try container.decodeIfPresent(Bool.self, forKey: .isTaxable) ?? true
        partNumber = try container.decodeIfPresent(String.self, forKey: .partNumber)
        confidence = Self.sanitizedUnitInterval(
            try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5,
            fallback: 0.5
        )
        kind = try container.decodeIfPresent(POItemKind.self, forKey: .kind) ?? .unknown
        kindConfidence = Self.sanitizedUnitInterval(
            try container.decodeIfPresent(Double.self, forKey: .kindConfidence) ?? 0,
            fallback: 0
        )
        kindReasons = try container.decodeIfPresent([String].self, forKey: .kindReasons) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sku, forKey: .sku)
        try container.encode(description, forKey: .description)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(unitCost, forKey: .unitCost)
        try container.encode(isTaxable, forKey: .isTaxable)
        try container.encodeIfPresent(partNumber, forKey: .partNumber)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(kind, forKey: .kind)
        try container.encode(kindConfidence, forKey: .kindConfidence)
        try container.encode(kindReasons, forKey: .kindReasons)
    }

    /// Decimal-accurate line subtotal used by the review UI.
    var subtotal: Decimal {
        let safeQuantity = quantity.isFinite ? quantity : 1
        return Decimal(safeQuantity) * unitCost
    }

    var isKindConfidenceHigh: Bool {
        kind != .unknown && kindConfidence >= 0.75
    }

    var isKindConfidenceMedium: Bool {
        kind != .unknown && kindConfidence >= 0.55 && kindConfidence < 0.75
    }

    var feeInferenceHint: String? {
        guard kind == .fee else { return nil }

        let serviceTerms = [
            "labor",
            "alignment",
            "install",
            "installation",
            "mount and balance",
            "mount & balance",
            "mounting",
            "balance service"
        ]

        for reason in kindReasons {
            let lowered = reason.lowercased()
            guard serviceTerms.contains(where: { lowered.contains($0) }) else { continue }

            if let extracted = quotedToken(in: reason), !extracted.isEmpty {
                return "Fee inferred: \(extracted)"
            }
            return "Fee inferred from service/labor terms"
        }

        return nil
    }

    // MARK: - Backward-compatible aliases

    var name: String {
        get { description }
        set { description = newValue }
    }

    var cost: Double {
        get { NSDecimalNumber(decimal: unitCost).doubleValue }
        set {
            let safeValue = newValue.isFinite ? newValue : 0
            unitCost = max(0, Decimal(safeValue))
        }
    }

    var costCents: Int {
        get { Self.roundedCents(from: unitCost) }
        set { unitCost = max(0, Decimal(newValue) / 100) }
    }

    var quantityForSubmission: Int {
        let safeQuantity = quantity.isFinite ? quantity : 1
        return max(1, Int(safeQuantity.rounded(.toNearestOrAwayFromZero)))
    }

    var unitPrice: Double? {
        get { cost }
        set { cost = newValue ?? 0 }
    }

    var total: Double? {
        NSDecimalNumber(decimal: subtotal).doubleValue
    }

    var unitPriceFormatted: String {
        Self.decimalFormatter.string(from: NSNumber(value: cost)) ?? String(format: "%.2f", cost)
    }

    var totalFormatted: String {
        let value = NSDecimalNumber(decimal: subtotal).doubleValue
        return Self.decimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    var subtotalFormatted: String {
        Self.currencyFormatter.string(from: NSDecimalNumber(decimal: subtotal)) ?? "$0.00"
    }

    private static func roundedCents(from cost: Decimal) -> Int {
        let centsDecimal = cost * 100
        let number = NSDecimalNumber(decimal: centsDecimal)
        let rounded = number.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        ))
        return rounded.intValue
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    private static func sanitizedQuantity(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return max(1, value)
    }

    private static func sanitizedUnitInterval(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }

    private func quotedToken(in reason: String) -> String? {
        guard let firstQuote = reason.firstIndex(of: "'") else { return nil }
        let tail = reason.index(after: firstQuote)
        guard tail < reason.endIndex else { return nil }
        guard let secondQuote = reason[tail...].firstIndex(of: "'"), secondQuote > tail else {
            return nil
        }

        let token = String(reason[tail..<secondQuote]).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
