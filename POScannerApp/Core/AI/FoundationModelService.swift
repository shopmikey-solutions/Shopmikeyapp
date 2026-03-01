//
//  FoundationModelService.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreParsing

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability wrapper to avoid leaking platform-specific Foundation Models types outside this file.
enum LanguageModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        } else {
            return false
        }
        #else
        return false
        #endif
    }
}

struct InvoiceItemAI: Decodable, Hashable {
    let description: String
    let partNumber: String?
    let quantity: Int?
    let unitCostCents: Int?
    let kind: String?
    let kindConfidence: Double?
    let kindReasons: [String]?
}

struct InvoiceAI: Decodable, Hashable {
    let vendorName: String?
    let vendorPhone: String?
    let vendorEmail: String?
    let poNumber: String?
    let invoiceNumber: String?
    let items: [InvoiceItemAI]
}

enum AIParsingError: Error {
    case modelUnavailable
    case invalidResponse
    case decodingFailed
}

final class AIParsingService {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    func parseInvoice(from ocrText: String, ignoreTaxAndTotals: Bool) async throws -> InvoiceAI {
        let filteredText: String
        if ignoreTaxAndTotals {
            let lines = ocrText
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            filteredText = filterNonProductLines(lines, ignoreTax: true).joined(separator: "\n")
        } else {
            filteredText = ocrText
        }

        let ignoreTaxRule = ignoreTaxAndTotals
            ? """

If ignoreTaxAndTotals is true:
- Do NOT include subtotal, total, tax, VAT, GST, HST, or similar summary lines in the items array.
- Items must represent purchasable goods or freight only.
"""
            : ""

        let prompt = """
You are a strict invoice data extraction engine.

Extract structured invoice data from the OCR text below.

Return ONLY valid JSON that matches the Swift structs:

InvoiceAI {
    vendorName: String?
    vendorPhone: String?
    vendorEmail: String?
    poNumber: String?
    invoiceNumber: String?
    items: [
        {
            description: String,
            partNumber: String?,
            quantity: Int?,
            unitCostCents: Int?,
            kind: String?,
            kindConfidence: Double?,
            kindReasons: [String]?
        }
    ]
}

Rules:

1. Output JSON only. No commentary. No markdown.
2. vendorName must be a company/business name, not a product.
3. Do NOT use line items as vendor name.
4. vendorPhone should be a vendor contact phone if present; otherwise null.
5. vendorEmail should be a vendor contact email if present; otherwise null.
6. invoiceNumber must resemble an invoice identifier (INV-xxxx, numeric ID, etc).
7. poNumber must resemble a purchase order number (PO-xxxx, etc).
8. Items must represent purchasable products, tires, or fees only.
9. Exclude labor/service lines (alignment, labor hours/rate, diagnostics, install labor).
10. Do NOT include subtotal, tax, or total as line items.
11. quantity must be an integer if present, otherwise null.
12. unitCostCents must be the price per unit in cents (not line total).
13. If only line total is available and quantity is known, divide to get unit cost.
14. If unsure about a field, return null.
15. Never invent data not present in the text.
16. kind must be one of: part, tire, fee, unknown.
17. kindConfidence must be between 0 and 1.
18. kindReasons should be a short list of extraction hints.

ignoreTaxAndTotals: \(ignoreTaxAndTotals ? "true" : "false")
\(ignoreTaxRule)

OCR TEXT:
\(filteredText)
"""

        guard LanguageModel.isAvailable else {
            throw AIParsingError.modelUnavailable
        }

        let session = LanguageModelSession(model: .default) { "" }
        let response = try await session.respond(to: prompt)
        let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8) else {
            throw AIParsingError.invalidResponse
        }

        do {
            let decoded = try decoder.decode(InvoiceAI.self, from: data)
            return validate(decoded)
        } catch {
            throw AIParsingError.decodingFailed
        }
    }
    #endif

    private func validate(_ invoice: InvoiceAI) -> InvoiceAI {
        let validatedItems = invoice.items.compactMap { item -> InvoiceItemAI? in
            let trimmedDescription = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPartNumber = item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = trimmedDescription.isEmpty ? (normalizedPartNumber ?? "") : trimmedDescription
            guard !description.isEmpty else {
                return nil
            }

            // Never allow summary/tax/total rows to become items.
            if InvoiceLineClassifier.isNonProductSummaryLine(description) {
                return nil
            }
            if InvoiceLineClassifier.isLaborServiceLine(description) {
                return nil
            }

            let safeQuantity = (item.quantity ?? 1) > 0 ? item.quantity ?? 1 : 1

            let safeCost: Int? = {
                if let cost = item.unitCostCents, cost > 0 && cost < 10_000_000 {
                    return cost
                }
                return nil
            }()

            let normalizedKind = POItemKind.from(rawValueOrAlias: item.kind)
            let safeKindConfidence: Double? = {
                guard let value = item.kindConfidence, value.isFinite else { return nil }
                return min(1.0, max(0.0, value))
            }()
            let safeKindReasons = (item.kindReasons ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return InvoiceItemAI(
                description: description,
                partNumber: normalizedPartNumber,
                quantity: safeQuantity,
                unitCostCents: safeCost,
                kind: normalizedKind.rawValue,
                kindConfidence: safeKindConfidence,
                kindReasons: safeKindReasons
            )
        }

        return InvoiceAI(
            vendorName: invoice.vendorName,
            vendorPhone: normalizedVendorPhone(invoice.vendorPhone),
            vendorEmail: normalizedVendorEmail(invoice.vendorEmail),
            poNumber: invoice.poNumber,
            invoiceNumber: invoice.invoiceNumber,
            items: validatedItems
        )
    }

    func asParsedInvoice(_ invoice: InvoiceAI) -> ParsedInvoice {
        let vendor = invoice.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let poNumber = invoice.poNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let invoiceNumber = invoice.invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        let items: [ParsedLineItem] = invoice.items.map { item in
            let normalizedPartNumber = item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
            let description: String = {
                let trimmed = item.description
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
                if let normalizedPartNumber, !normalizedPartNumber.isEmpty {
                    return normalizedPartNumber
                }
                return "Untitled Item"
            }()

            let localSuggestion = LineItemSuggestionService.classify(
                description: description,
                partNumber: normalizedPartNumber,
                contextText: description
            )
            let aiKind = POItemKind.from(rawValueOrAlias: item.kind)
            let aiConfidence: Double = {
                guard let value = item.kindConfidence, value.isFinite else { return 0.0 }
                return min(1.0, max(0.0, value))
            }()
            let aiReasons = (item.kindReasons ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let finalKind: POItemKind
            let finalKindConfidence: Double
            let finalKindReasons: [String]
            if aiKind != .unknown, aiConfidence >= localSuggestion.confidence + 0.05 {
                finalKind = aiKind
                finalKindConfidence = aiConfidence
                finalKindReasons = aiReasons.isEmpty ? ["classified from OCR + AI"] : aiReasons
            } else if aiKind == localSuggestion.kind, aiKind != .unknown {
                finalKind = aiKind
                finalKindConfidence = max(localSuggestion.confidence, aiConfidence)
                finalKindReasons = Array(Set(localSuggestion.reasons + aiReasons)).sorted()
            } else {
                finalKind = localSuggestion.kind
                finalKindConfidence = localSuggestion.confidence
                finalKindReasons = localSuggestion.reasons
            }

            var score: Double = 0.2
            if let vendor, !vendor.isEmpty { score += 0.2 }
            if item.quantity != nil { score += 0.2 }
            if item.unitCostCents != nil { score += 0.2 }
            if let pn = normalizedPartNumber, !pn.isEmpty { score += 0.2 }
            let confidence = min(1.0, score)

            return ParsedLineItem(
                name: description,
                quantity: item.quantity,
                costCents: item.unitCostCents,
                partNumber: normalizedPartNumber,
                confidence: confidence,
                kind: finalKind,
                kindConfidence: finalKindConfidence,
                kindReasons: finalKindReasons
            )
        }

        let totalCents = items.reduce(0) { partial, item in
            partial + ((item.costCents ?? 0) * max(1, item.quantity ?? 1))
        }

        return ParsedInvoice(
            vendorName: vendor,
            poNumber: poNumber,
            invoiceNumber: invoiceNumber?.isEmpty == true ? nil : invoiceNumber,
            totalCents: totalCents > 0 ? totalCents : nil,
            items: items,
            header: POHeaderFields(
                vendorName: vendor ?? "",
                vendorPhone: normalizedVendorPhone(invoice.vendorPhone),
                vendorEmail: normalizedVendorEmail(invoice.vendorEmail),
                vendorInvoiceNumber: invoiceNumber ?? "",
                poReference: poNumber ?? ""
            )
        )
    }

    private func normalizedVendorPhone(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let pattern = #"(?:\+?1[\s\-.]?)?(?:\(?\d{3}\)?[\s\-.]?)\d{3}[\s\-.]?\d{4}(?:\s*(?:ext|x)\s*\d{1,5})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              let matchRange = Range(match.range, in: value) else {
            return nil
        }

        let cleaned = String(value[matchRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        return cleaned.count >= 10 ? cleaned : nil
    }

    private func normalizedVendorEmail(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              let matchRange = Range(match.range, in: value) else {
            return nil
        }

        return String(value[matchRange]).lowercased()
    }
}

/// Optional parsing augmentation using Apple Foundation Models when available.
/// This is strictly optional and always falls back to `POParser`.
final class FoundationModelService {
    private let cache = OnDeviceParseCache(limit: 24)

    var isOnDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return LanguageModel.isAvailable
        }
        return false
        #else
        return false
        #endif
    }

    func parseInvoiceIfAvailable(from text: String, ignoreTaxAndTotals: Bool = false) async -> ParsedInvoice? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard isOnDeviceModelAvailable else {
                return nil
            }

            let key = cacheKey(for: text, ignoreTaxAndTotals: ignoreTaxAndTotals)
            if let cached = await cache.value(for: key) {
                return cached
            }

            do {
                let service = AIParsingService()
                let ai = try await service.parseInvoice(from: text, ignoreTaxAndTotals: ignoreTaxAndTotals)
                let parsed = service.asParsedInvoice(ai)
                await cache.insert(parsed, for: key)
                return parsed
            } catch {
                return nil
            }
        }
        #endif

        _ = text
        return nil
    }

    private func cacheKey(for text: String, ignoreTaxAndTotals: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(ignoreTaxAndTotals)
        hasher.combine(text)
        return hasher.finalize()
    }
}

private actor OnDeviceParseCache {
    private let limit: Int
    private var order: [Int] = []
    private var values: [Int: ParsedInvoice] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func value(for key: Int) -> ParsedInvoice? {
        values[key]
    }

    func insert(_ invoice: ParsedInvoice, for key: Int) {
        values[key] = invoice
        if let existingIndex = order.firstIndex(of: key) {
            order.remove(at: existingIndex)
        }
        order.append(key)

        if order.count > limit, let evicted = order.first {
            order.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }
}
