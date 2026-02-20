//
//  LineItemSuggestionService.swift
//  POScannerApp
//

import CoreData
import Foundation

struct LineItemKindSuggestion: Hashable {
    var kind: POItemKind
    var confidence: Double
    var reasons: [String]
    var suggestedPartNumber: String?
    var normalizedDescription: String
}

struct SuggestedLineItem: Hashable {
    var item: POItem
    var wasAutoApplied: Bool
}

final class LineItemSuggestionService {
    static let highConfidenceThreshold: Double = 0.75
    static let tentativeConfidenceThreshold: Double = 0.55

    private let context: NSManagedObjectContext?

    init(context: NSManagedObjectContext? = nil) {
        self.context = context
    }

    func suggest(items: [POItem], parsedItems: [ParsedLineItem] = []) async -> [POItem] {
        let historyIndex = await loadHistoryIndex()
        return items.enumerated().map { index, item in
            let parsedItem = parsedItems.indices.contains(index) ? parsedItems[index] : nil
            let suggestion = mergedSuggestion(for: item, parsedItem: parsedItem, historyIndex: historyIndex)
            return applySuggestion(suggestion, to: item)
        }
    }

    static func classify(
        description: String,
        partNumber: String? = nil,
        contextText: String? = nil
    ) -> LineItemKindSuggestion {
        let normalizedDescription = normalizeWhitespace(description)
        let loweredDescription = normalizedDescription.lowercased()
        let loweredContext = normalizeWhitespace(contextText ?? "").lowercased()
        let loweredPart = normalizeWhitespace(partNumber ?? "").lowercased()
        let joinedContext = [loweredDescription, loweredContext, loweredPart]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let hasBatterySignal = joinedContext.range(
            of: #"\b(battery|agm|cca|diehard)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        var scores: [POItemKind: Double] = [
            .part: 0.0,
            .tire: 0.0,
            .fee: 0.0
        ]
        var reasons: [POItemKind: [String]] = [
            .part: [],
            .tire: [],
            .fee: []
        ]

        func addScore(_ kind: POItemKind, amount: Double, reason: String) {
            scores[kind, default: 0] = min(1.0, scores[kind, default: 0] + amount)
            reasons[kind, default: []].append(reason)
        }

        for term in feeSignals where joinedContext.contains(term) {
            addScore(.fee, amount: 0.30, reason: "contains fee term '\(term)'")
        }

        if loweredDescription.range(
            of: #"^\s*(shipping|freight|shop[-\s]?fee|shop supplies|environmental|environmental charge|env[-\s]?fee|hazmat|disposal|surcharge|tax|core charge)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            addScore(.fee, amount: 0.35, reason: "starts with fee term")
        }

        if joinedContext.range(
            of: #"(?i)\b(shop[-\s]?fee|env[-\s]?fee|disposal fee|core charge|environmental charge)\b"#,
            options: .regularExpression
        ) != nil {
            addScore(.fee, amount: 0.35, reason: "matches structured fee token")
        }

        if joinedContext.range(of: #"(?i)\b(tax|vat|gst|hst)\b"#, options: .regularExpression) != nil {
            addScore(.fee, amount: 0.22, reason: "contains tax keyword")
        }

        for term in tireSignals where joinedContext.contains(term) {
            addScore(.tire, amount: 0.24, reason: "contains tire term '\(term)'")
        }

        if let size = firstTireSize(in: joinedContext) {
            let tireSizeWeight = hasBatterySignal ? 0.18 : 0.65
            addScore(.tire, amount: tireSizeWeight, reason: "matches tire size '\(size)'")
        }

        for brand in tireBrands where joinedContext.contains(brand) {
            addScore(.tire, amount: 0.16, reason: "contains tire brand '\(brand)'")
        }

        for term in partSignals where joinedContext.contains(term) {
            addScore(.part, amount: 0.16, reason: "contains part term '\(term)'")
        }

        if hasBatterySignal {
            addScore(.part, amount: 0.30, reason: "contains battery term")
        }

        let suggestedPartNumber = suggestedPartNumber(from: normalizedDescription, explicitPartNumber: partNumber)
        if let suggestedPartNumber, !suggestedPartNumber.isEmpty {
            addScore(.part, amount: 0.40, reason: "has part-number token '\(suggestedPartNumber)'")
        }

        let rankedKinds = scores
            .map { (kind: $0.key, score: min(1.0, $0.value)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.kind.rawValue < $1.kind.rawValue
            }

        let top = rankedKinds.first ?? (kind: .unknown, score: 0)
        let second = rankedKinds.dropFirst().first?.score ?? 0
        let margin = top.score - second

        let inferredKind: POItemKind
        let inferredConfidence: Double
        var inferredReasons: [String]

        if top.score < tentativeConfidenceThreshold {
            inferredKind = .unknown
            inferredConfidence = max(0, top.score)
            inferredReasons = ["line type confidence below threshold"]
        } else if margin < 0.10 && top.score < 0.85 {
            inferredKind = .unknown
            inferredConfidence = max(0, top.score - 0.05)
            inferredReasons = ["line type is ambiguous across categories"]
        } else {
            inferredKind = top.kind
            inferredConfidence = min(1.0, top.score)
            inferredReasons = reasons[top.kind, default: []]
        }

        if inferredReasons.isEmpty {
            inferredReasons = ["line classified from deterministic parser rules"]
        }

        return LineItemKindSuggestion(
            kind: inferredKind,
            confidence: min(1.0, max(0, inferredConfidence)),
            reasons: Array(inferredReasons.prefix(3)),
            suggestedPartNumber: suggestedPartNumber,
            normalizedDescription: normalizedDescription
        )
    }

    // MARK: - Private

    private struct HistoryAggregate {
        var canonicalName: String
        var observations: Int
        var kindCounts: [POItemKind: Int]
    }

    private func mergedSuggestion(
        for item: POItem,
        parsedItem: ParsedLineItem?,
        historyIndex: [String: HistoryAggregate]
    ) -> LineItemKindSuggestion {
        var base = Self.classify(
            description: item.description,
            partNumber: item.partNumber ?? item.sku,
            contextText: item.description
        )

        if let parsedItem {
            let parsedKind = parsedItem.kind
            let parsedConfidence = min(1.0, max(0, parsedItem.kindConfidence))
            if parsedKind != .unknown {
                if base.kind == parsedKind {
                    base.confidence = max(base.confidence, parsedConfidence)
                    base.reasons.append(contentsOf: parsedItem.kindReasons)
                } else if parsedConfidence > base.confidence + 0.05 {
                    base.kind = parsedKind
                    base.confidence = parsedConfidence
                    base.reasons = parsedItem.kindReasons.isEmpty
                        ? ["inferred from OCR + AI line parsing"]
                        : parsedItem.kindReasons
                } else if abs(parsedConfidence - base.confidence) <= 0.05 {
                    base.kind = .unknown
                    base.confidence = min(base.confidence, parsedConfidence)
                    base.reasons = ["line type is ambiguous between parser and AI suggestions"]
                }
            }
        }

        let normalizedKey = base.normalizedDescription.normalizedVendorName
        if let history = historyIndex[normalizedKey] {
            if base.kind == .unknown, let historyKind = dominantHistoryKind(from: history.kindCounts) {
                base.kind = historyKind
                base.confidence = max(base.confidence, 0.60)
                base.reasons.append("matched previous submitted line item")
            } else if let historyKind = dominantHistoryKind(from: history.kindCounts), historyKind == base.kind {
                base.confidence = min(1.0, base.confidence + 0.12)
                base.reasons.append("type reinforced by submission history")
            }

            if !history.canonicalName.isEmpty {
                base.normalizedDescription = history.canonicalName
            }
        }

        if base.reasons.isEmpty {
            base.reasons = ["line classified from deterministic parser rules"]
        }
        base.reasons = Array(Set(base.reasons)).sorted()
        return base
    }

    private func applySuggestion(_ suggestion: LineItemKindSuggestion, to item: POItem) -> POItem {
        var updated = item
        updated.kindConfidence = suggestion.confidence
        updated.kindReasons = suggestion.reasons

        if suggestion.confidence >= Self.tentativeConfidenceThreshold {
            updated.kind = suggestion.kind
        } else {
            updated.kind = .unknown
        }

        if suggestion.confidence >= Self.highConfidenceThreshold {
            if updated.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.description = suggestion.normalizedDescription
            }

            let partNumberIsEmpty = updated.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            if partNumberIsEmpty, let suggestedPartNumber = suggestion.suggestedPartNumber {
                updated.partNumber = suggestedPartNumber
                if updated.sku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updated.sku = suggestedPartNumber
                }
            }
        }

        updated.description = Self.normalizeWhitespace(updated.description)
        return updated
    }

    private func loadHistoryIndex() async -> [String: HistoryAggregate] {
        guard let context else { return [:] }

        return await context.perform {
            let request: NSFetchRequest<Item> = Item.fetchRequest()
            request.fetchLimit = 250
            request.sortDescriptors = [NSSortDescriptor(key: "purchaseOrder.date", ascending: false)]

            let rows = (try? context.fetch(request)) ?? []
            var index: [String: HistoryAggregate] = [:]

            for row in rows {
                let normalized = Self.normalizeWhitespace(row.name)
                guard !normalized.isEmpty else { continue }

                let key = normalized.normalizedVendorName
                guard !key.isEmpty else { continue }

                let classified = Self.classify(description: normalized, partNumber: nil, contextText: nil)
                var aggregate = index[key] ?? HistoryAggregate(
                    canonicalName: normalized,
                    observations: 0,
                    kindCounts: [:]
                )
                aggregate.observations += 1
                aggregate.kindCounts[classified.kind, default: 0] += 1
                if aggregate.canonicalName.isEmpty {
                    aggregate.canonicalName = normalized
                }
                index[key] = aggregate
            }

            return index
        }
    }

    private func dominantHistoryKind(from counts: [POItemKind: Int]) -> POItemKind? {
        let ranked = counts
            .filter { $0.key != .unknown }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }

        guard let first = ranked.first, first.value > 0 else {
            return nil
        }
        return first.key
    }
}

private extension LineItemSuggestionService {
    static let feeSignals: [String] = [
        "shipping",
        "freight",
        "shop-fee",
        "shop fee",
        "env-fee",
        "env fee",
        "core",
        "core charge",
        "hazmat",
        "disposal",
        "disposal fee",
        "shop supplies",
        "environmental",
        "environmental charge",
        "surcharge",
        "labor",
        "alignment",
        "install",
        "installation",
        "mount and balance",
        "mount & balance",
        "mounting",
        "balance service"
    ]

    static let tireSignals: [String] = [
        "tire",
        "tyre",
        "run-flat",
        "run flat",
        "load index",
        "speed rating",
        "utqg",
        "side wall",
        "sidewall"
    ]

    static let tireBrands: [String] = [
        "michelin",
        "bridgestone",
        "goodyear",
        "continental",
        "pirelli",
        "yokohama",
        "toyo",
        "cooper",
        "hankook",
        "kumho",
        "nitto",
        "falken"
    ]

    static let partSignals: [String] = [
        "part",
        "battery",
        "filter",
        "pad",
        "rotor",
        "brake",
        "compressor",
        "assembly",
        "kit",
        "sensor",
        "ignition",
        "coil",
        "fluid",
        "coolant",
        "wiper",
        "blade",
        "gasket",
        "hub",
        "bearing",
        "alternator",
        "starter"
    ]

    static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstTireSize(in text: String) -> String? {
        let patterns = [
            #"\b\d{3}/\d{2,3}/\d{2}\b"#,
            #"\b\d{3}/\d{2,3}(?:zr|r|-)?\d{2}\b"#,
            #"\b\d{2,3}/\d{2}zr\d{2}\b"#,
            #"\b\d{2,3}/\d{2}r\d{2}\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let matchRange = Range(match.range, in: text) else {
                continue
            }
            return String(text[matchRange]).uppercased()
        }

        return nil
    }

    static func suggestedPartNumber(from description: String, explicitPartNumber: String?) -> String? {
        let explicit = normalizeWhitespace(explicitPartNumber ?? "")
        if !explicit.isEmpty {
            return explicit.uppercased()
        }

        let pattern = #"\b[A-Z]{1,6}[A-Z0-9]*[-][A-Z0-9-]{2,}\b|\b[A-Z]{1,4}\d[A-Z0-9-]{2,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let source = description.uppercased()
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let matchRange = Range(match.range, in: source) else {
            return nil
        }

        let token = source[matchRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
