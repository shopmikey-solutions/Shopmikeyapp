//
//  VendorSummary.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct VendorSummary: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let phone: String?
    public let email: String?
    public let notes: String?

    public init(
        id: String,
        name: String,
        phone: String? = nil,
        email: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.phone = phone
        self.email = email
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let root = try VendorJSONValue(from: decoder)

        self.id = Self.firstString(
            keys: ["id", "vendor_id", "vendorId"],
            in: root
        ) ?? ""
        self.name = Self.firstString(
            keys: ["name", "vendor_name", "vendorName"],
            in: root
        ) ?? ""
        self.phone = Self.firstString(
            keys: ["phone", "phone_number", "phoneNumber", "telephone", "mobile"],
            in: root
        )
        self.email = Self.firstString(
            keys: ["email", "email_address", "emailAddress", "primary_email", "primaryEmail"],
            in: root
        )
        self.notes = Self.firstNonEmpty([
            Self.firstString(keys: ["vendor_notes", "vendorNotes"], in: root),
            Self.firstString(keys: ["notes", "note"], in: root)
        ])
    }

    private static func firstString(keys: [String], in value: VendorJSONValue) -> String? {
        let lookup = Set(keys.map { $0.lowercased() })
        return firstString(matching: lookup, in: value)
    }

    private static func firstString(matching keys: Set<String>, in value: VendorJSONValue) -> String? {
        switch value {
        case .object(let object):
            for (rawKey, nestedValue) in object {
                if keys.contains(rawKey.lowercased()),
                   let scalar = scalarString(from: nestedValue) {
                    let trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }

            for nestedValue in object.values {
                if let found = firstString(matching: keys, in: nestedValue) {
                    return found
                }
            }
            return nil

        case .array(let values):
            for nestedValue in values {
                if let found = firstString(matching: keys, in: nestedValue) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func scalarString(from value: VendorJSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}

private enum VendorJSONValue: Decodable {
    case object([String: VendorJSONValue])
    case array([VendorJSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKeys.self) {
            var dictionary: [String: VendorJSONValue] = [:]
            for key in container.allKeys {
                dictionary[key.stringValue] = try container.decode(VendorJSONValue.self, forKey: key)
            }
            self = .object(dictionary)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [VendorJSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(VendorJSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON payload"
            )
        }
    }
}

private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    var intValue: Int?
    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }
}
