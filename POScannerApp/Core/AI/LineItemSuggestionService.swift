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

        for phrase in partPhraseSignals where joinedContext.contains(phrase) {
            addScore(.part, amount: 0.28, reason: "matches part phrase '\(phrase)'")
        }

        if hasBatterySignal {
            addScore(.part, amount: 0.30, reason: "contains battery term")
        }

        let suggestedPartNumber = suggestedPartNumber(from: normalizedDescription, explicitPartNumber: partNumber)
        if let suggestedPartNumber, !suggestedPartNumber.isEmpty {
            addScore(.part, amount: 0.40, reason: "has part-number token '\(suggestedPartNumber)'")
        }

        let partTermHitCount = partSignals.reduce(into: 0) { partial, term in
            if joinedContext.contains(term) { partial += 1 }
        }
        if partTermHitCount >= 2 {
            addScore(.part, amount: 0.20, reason: "contains multiple part signals")
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

    static func preferredPartNumber(
        from description: String,
        explicitPartNumber: String? = nil
    ) -> String? {
        suggestedPartNumber(from: description, explicitPartNumber: explicitPartNumber)
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
        "spark",
        "plug",
        "pad",
        "rotor",
        "brake",
        "axle",
        "clutch",
        "flywheel",
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
        "belt",
        "tensioner",
        "alternator",
        "starter",
        "remanufactured"
    ]

    static let partPhraseSignals: [String] = [
        "cv axle",
        "clutch kit",
        "spark plug",
        "drive belt tensioner",
        "performance axle",
        "drive axle",
        "solid flywheel"
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
        let source = description.uppercased()

        let explicit = normalizeWhitespace(explicitPartNumber ?? "").uppercased()
        if !explicit.isEmpty {
            let normalized = normalizePartNumberToken(explicit)
            if isLikelyExplicitPartNumberToken(normalized)
                || scoreForPartNumberCandidate(normalized, in: source) >= 24 {
                return normalized
            }
        }

        guard let best = bestPartNumberCandidate(in: source), best.score >= 24 else {
            return nil
        }
        return best.token
    }

    private struct PartNumberCandidate {
        let token: String
        let score: Int
    }

    private static func bestPartNumberCandidate(in source: String) -> PartNumberCandidate? {
        let rawTokens = source.split(whereSeparator: \.isWhitespace).map(String.init)
        var best: PartNumberCandidate?

        for raw in rawTokens {
            let token = normalizePartNumberToken(raw)
            guard token.count >= 4 else { continue }
            let hasLetters = token.rangeOfCharacter(from: .letters) != nil
            let hasDigits = token.rangeOfCharacter(from: .decimalDigits) != nil
            guard hasDigits else { continue }
            let hasNonDigits = token.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil

            let isNumericHyphenCode = token.range(
                of: #"^\d{2,6}-\d{2,6}$"#,
                options: .regularExpression
            ) != nil
            if !hasLetters && !(hasNonDigits && isNumericHyphenCode) {
                continue
            }

            let score = scoreForPartNumberCandidate(token, in: source)
            if let best, best.score > score {
                continue
            }
            best = PartNumberCandidate(token: token, score: score)
        }

        return best
    }

    private static func normalizePartNumberToken(_ token: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return token
            .trimmingCharacters(in: allowed.inverted)
            .uppercased()
    }

    private static func isLikelyExplicitPartNumberToken(_ token: String) -> Bool {
        guard token.count >= 4 else { return false }
        guard token.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        guard firstTireSize(in: token) == nil else { return false }
        guard token.range(of: #"^[A-Z0-9-]{4,}$"#, options: .regularExpression) != nil else {
            return false
        }

        let disallowed: Set<String> = [
            "QTY",
            "EA",
            "PCS",
            "TOTAL",
            "SUBTOTAL",
            "ORDER",
            "LINE"
        ]
        return !disallowed.contains(token)
    }

    private static func scoreForPartNumberCandidate(_ token: String, in source: String) -> Int {
        guard !token.isEmpty else { return .min }

        // Reject tire size formats outright.
        if firstTireSize(in: token) != nil {
            return .min
        }

        var score = 0
        if token.contains("-") { score += 28 }
        if token.range(of: #"^[A-Z]{2,8}[-][A-Z0-9-]{2,}$"#, options: .regularExpression) != nil { score += 24 }
        if token.range(of: #"^[A-Z]{1,6}\d[A-Z0-9-]{1,}$"#, options: .regularExpression) != nil { score += 18 }
        if token.range(of: #"^\d{2,6}-\d{2,6}$"#, options: .regularExpression) != nil { score += 16 }
        if token.range(of: #"[A-Z]"#, options: .regularExpression) != nil { score += 8 }
        if token.range(of: #"\d"#, options: .regularExpression) != nil { score += 8 }

        let containsServiceSignal = token.range(
            of: #"(ALIGN|ALGN|SERVICE|LABOR|INSTALL|MOUNT|BALANCE)"#,
            options: .regularExpression
        ) != nil
        if containsServiceSignal { score -= 30 }

        let unitSuffixPenalty = token.range(
            of: #"(?:CCA|MHZ|MM|CM|IN|HR|HRS)$"#,
            options: .regularExpression
        ) != nil
        if unitSuffixPenalty { score -= 18 }

        if token.range(of: #"^\d+[A-Z]{2,}$"#, options: .regularExpression) != nil {
            score -= 20
        }

        if token.count > 22 { score -= 10 }

        // Prefer tokens that appear near explicit part markers.
        let escapedToken = NSRegularExpression.escapedPattern(for: token)
        let labeledPattern = "(?:PN|P/N|PART#?|SKU)[:\\s\\-]*\(escapedToken)"
        if source.range(of: labeledPattern, options: .regularExpression) != nil {
            score += 14
        }

        return score
    }
}
