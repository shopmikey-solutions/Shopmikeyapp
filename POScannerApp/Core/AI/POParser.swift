//
//  POParser.swift
//  POScannerApp
//

import Foundation

/// Regex-based parser with basic confidence scoring.
///
/// - Important: Parsing is pure text -> model only. No Core Data, no networking, no shared state.
final class POParser: @unchecked Sendable {
    func parse(from text: String, ignoreTaxAndTotals: Bool = false) -> ParsedInvoice {
        let lines = nonEmptyLines(from: text)
        let firstLine = lines.first

        let vendorName: String?
        if let firstLine, firstLine.containsVendorKeywords {
            vendorName = firstLine
        } else {
            vendorName = nil
        }

        var poNumber = extractPONumber(from: text)
        var invoiceNumber = extractInvoiceNumber(from: text)
        if shouldSwapDocumentIdentifiers(invoiceNumber: invoiceNumber, poNumber: poNumber) {
            swap(&poNumber, &invoiceNumber)
        }
        let items = extractLineItems(
            from: text,
            skippingFirstNonEmptyLine: vendorName != nil,
            vendorMatch: vendorName != nil,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
        let normalizedItems = normalizeDescriptions(items)
        let totalCents = normalizedItems.reduce(0) { partial, item in
            partial + ((item.costCents ?? 0) * max(1, item.quantity ?? 1))
        }

        #if DEBUG
        print("Vendor extracted: \(vendorName ?? "nil")")
        print("Items parsed: \(normalizedItems.count)")
        #endif

        return ParsedInvoice(
            vendorName: vendorName,
            poNumber: poNumber,
            invoiceNumber: invoiceNumber,
            totalCents: totalCents > 0 ? totalCents : nil,
            items: normalizedItems,
            header: POHeaderFields(
                vendorName: vendorName ?? "",
                vendorInvoiceNumber: invoiceNumber ?? "",
                poReference: poNumber ?? ""
            )
        )
    }

    // MARK: - PO number

    private func extractPONumber(from text: String) -> String? {
        extractIdentifier(
            from: text,
            inlinePatterns: [
                #"(?i)\bPO[ \t]*(?:NUMBER|NO\.?|NO|#)?[ \t]*[:#]?[ \t]*([A-Z0-9][A-Z0-9-]{1,})"#
            ],
            labelOnlyPattern: #"(?i)^\s*PO[ \t]*(?:NUMBER|NO\.?|NO|#)?[ \t]*[:#]?\s*$"#
        )
    }

    private func extractInvoiceNumber(from text: String) -> String? {
        extractIdentifier(
            from: text,
            inlinePatterns: [
                #"(?i)\bInvoice[ \t]*(?:No\.?|#|Number)?[ \t]*[:#]?[ \t]*([A-Z0-9][A-Z0-9\-]*)"#,
                #"(?i)\bInv[ \t]*(?:No\.?|#|Number)?[ \t]*[:#]?[ \t]*([A-Z0-9][A-Z0-9\-]*)"#
            ],
            labelOnlyPattern: #"(?i)^\s*(Invoice|Inv)[ \t]*(?:No\.?|#|Number)?[ \t]*[:#]?\s*$"#
        )
    }

    // MARK: - Line items

    private let qtyPatterns: [String] = [
        #"(?i)(qty|quantity)[:\s]*(\d+)"#,
        #"(?i)\b(\d+)\s*(ea|pcs|x)\b"#,
        #"(?i)\bx(\d+)\b"#
    ]

    private let costPattern: String = #"\$?\s?(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#
    private let monetaryTokenPattern: String = #"\$?\s*\d{1,3}(?:,\d{3})*\.\d{2}\b"#

    private let partPattern: String = #"(?i)(pn|p\/n|part#?)[:\s]*([A-Z0-9\-]+)"#

    private func extractLineItems(
        from text: String,
        skippingFirstNonEmptyLine: Bool,
        vendorMatch: Bool,
        ignoreTaxAndTotals: Bool
    ) -> [ParsedLineItem] {
        var lines = nonEmptyLines(from: text)
        if skippingFirstNonEmptyLine, !lines.isEmpty {
            lines.removeFirst()
        }

        // Currency-agnostic semantic filtering for tax/total lines when enabled.
        lines = filterNonProductLines(lines, ignoreTax: ignoreTaxAndTotals)

        var blocks: [[String]] = []
        var current: [String] = []

        for line in lines {
            if isIgnorableLine(line) {
                continue
            }

            let attributeOnly = isAttributeOnlyLine(line)
            let nameLike = isNameLikeLine(line)

            if current.isEmpty {
                if attributeOnly {
                    continue
                }
                current = [line]
                continue
            }

            if nameLike, !attributeOnly, shouldStartNewItemBlock(with: line, currentBlock: current) {
                blocks.append(current)
                current = [line]
            } else {
                current.append(line)
            }
        }

        if !current.isEmpty {
            blocks.append(current)
        }

        let items = blocks.map { parseItemBlock($0, vendorMatch: vendorMatch) }
        return items.filter(isValidParsedItem)
    }
}

private extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private extension POParser {
    func isValidParsedItem(_ item: ParsedLineItem) -> Bool {
        let description = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return false
        }

        let unitCents = item.costCents ?? 0
        let qty = max(1, item.quantity ?? 1)
        let totalCents = unitCents * qty

        // Drop zero-money rows.
        if unitCents == 0 && totalCents == 0 {
            return false
        }

        // Drop short ALL CAPS header-style rows.
        if description == description.uppercased(),
           description.count < 25,
           unitCents == 0 {
            return false
        }

        // Drop known summary labels.
        let upper = description.uppercased()
        let hardBannedKeywords = ["WAREHOUSE", "SUMMARY"]
        if hardBannedKeywords.contains(where: { upper.contains($0) }) {
            return false
        }

        // Treat financial summary labels as invalid rows unless the line looks product-like.
        let summaryKeywords = ["SUBTOTAL", "TOTAL", "TAX", "BALANCE"]
        if summaryKeywords.contains(where: { upper.contains($0) }),
           (InvoiceLineClassifier.isNonProductSummaryLine(description) || !looksLikeProductRow(description, item: item)) {
            return false
        }

        return true
    }

    func looksLikeProductRow(_ description: String, item: ParsedLineItem) -> Bool {
        if (item.costCents ?? 0) > 0 {
            return true
        }
        if (item.quantity ?? 1) > 1 {
            return true
        }

        // Keep known product-like lines that happen to include terms like "TOTAL".
        if description.range(of: #"\b(qty|quantity)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if description.range(of: #"\b\d+\s*(ea|pcs|pc|x)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if description.range(of: #"(?i)[A-Z]*\d[A-Z0-9-]{2,}"#, options: [.regularExpression]) != nil {
            return true
        }
        return false
    }

    func nonEmptyLines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func isIgnorableLine(_ line: String) -> Bool {
        // Always ignore non-product summary lines (tax/subtotal/total). These must never become items.
        if InvoiceLineClassifier.isNonProductSummaryLine(line) { return true }

        let lower = line.lowercased()
        if lower.contains("purchase order") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("po:") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("po #") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("po no") { return true }
        return false
    }

    func isAttributeOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Pure cost lines like "$129.99".
        if trimmed.rangeOfCharacter(from: .letters) == nil, extractCost(from: trimmed).found {
            return true
        }

        // If stripping known attribute patterns leaves nothing, treat it as attribute-only.
        var scratch = trimmed

        if let regex = try? NSRegularExpression(pattern: partPattern) {
            let range = NSRange(scratch.startIndex..<scratch.endIndex, in: scratch)
            scratch = regex.stringByReplacingMatches(in: scratch, options: [], range: range, withTemplate: "")
        }

        for pattern in qtyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(scratch.startIndex..<scratch.endIndex, in: scratch)
                scratch = regex.stringByReplacingMatches(in: scratch, options: [], range: range, withTemplate: "")
            }
        }

        if let regex = try? NSRegularExpression(pattern: costPattern) {
            let range = NSRange(scratch.startIndex..<scratch.endIndex, in: scratch)
            scratch = regex.stringByReplacingMatches(in: scratch, options: [], range: range, withTemplate: "")
        }

        scratch = scratch
            .replacingOccurrences(of: "[\\s:#$]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return scratch.isEmpty
    }

    func isNameLikeLine(_ line: String) -> Bool {
        line.rangeOfCharacter(from: .letters) != nil
    }

    func shouldStartNewItemBlock(with line: String, currentBlock: [String]) -> Bool {
        // If the current block already has something beyond a single name line, a new name-like line likely starts a new item.
        if currentBlock.count >= 2 {
            return true
        }

        // If the current name line already contains cost/qty/part number, treat the next name-like line as a new block.
        let currentText = currentBlock.joined(separator: "\n")
        if extractCost(from: currentText).found || extractQuantity(from: currentText).found || extractPartNumber(from: currentText).found {
            return true
        }

        // Otherwise keep appending; some vendors wrap item descriptions across multiple lines.
        _ = line
        return false
    }

    func parseItemBlock(_ lines: [String], vendorMatch: Bool) -> ParsedLineItem {
        let combined = lines.joined(separator: "\n")
        let descriptionLine = preferredDescriptionLine(from: lines)

        let qtyResult = extractQuantity(from: combined)
        let costResult = extractCost(from: combined, quantityHint: qtyResult.found ? qtyResult.value : nil)
        let partResult = extractPartNumber(from: combined)

        let name = cleanItemName(
            from: descriptionLine,
            partNumber: partResult.value,
            quantity: qtyResult.value
        )

        var score = 0.2
        if qtyResult.found { score += 0.2 }
        if costResult.found { score += 0.2 }
        if partResult.found { score += 0.2 }
        if costResult.hadCurrencySymbol { score += 0.2 }
        if vendorMatch { score += 0.2 }
        let confidence = min(1.0, score)
        let kindSuggestion = LineItemSuggestionService.classify(
            description: name,
            partNumber: partResult.value,
            contextText: combined
        )

        return ParsedLineItem(
            name: name,
            quantity: qtyResult.found ? qtyResult.value : nil,
            costCents: costResult.found ? costResult.cents : nil,
            partNumber: partResult.value,
            confidence: confidence,
            kind: kindSuggestion.kind,
            kindConfidence: kindSuggestion.confidence,
            kindReasons: kindSuggestion.reasons
        )
    }

    func preferredDescriptionLine(from lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }

        let candidates = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
            guard !isAttributeOnlyLine(trimmed) else { return false }
            guard !InvoiceLineClassifier.isNonProductSummaryLine(trimmed) else { return false }
            return true
        }

        let scored = (candidates.isEmpty ? lines : candidates).map { line in
            (line, descriptionSignalScore(line))
        }

        return scored.max(by: { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.count < rhs.0.count
            }
            return lhs.1 < rhs.1
        })?.0 ?? lines[0]
    }

    func descriptionSignalScore(_ line: String) -> Int {
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return (letters * 5) + line.count - (digits * 2)
    }

    func extractQuantity(from text: String) -> (value: Int, found: Bool) {
        for pattern in qtyPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { continue }

            let groupIndex: Int
            switch pattern {
            case qtyPatterns[0]:
                groupIndex = 2
            default:
                groupIndex = 1
            }

            guard match.numberOfRanges > groupIndex, let r = Range(match.range(at: groupIndex), in: text) else { continue }
            if let value = Int(text[r]), value >= 1 {
                return (value, true)
            }
        }

        // Fallback for table-style rows:
        // infer quantity from the numeric token immediately before the first monetary value.
        if let moneyRange = firstMonetaryTokenRange(in: text) {
            let prefix = text[..<moneyRange.lowerBound]
            if let lastToken = prefix.split(whereSeparator: \.isWhitespace).last,
               let value = Int(lastToken),
               (1...200).contains(value) {
                return (value, true)
            }
        }

        // Fallback: leading quantity like "2 Brake Pads ..."
        let leadingPattern = #"^\s*(\d+)\s+"#
        if let regex = try? NSRegularExpression(pattern: leadingPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: text),
               let value = Int(text[r]),
               value >= 1 {
                return (value, true)
            }
        }

        return (1, false)
    }

    func extractCost(from text: String, quantityHint: Int? = nil) -> (cents: Int, found: Bool, hadCurrencySymbol: Bool) {
        guard let regex = try? NSRegularExpression(pattern: costPattern) else {
            return (0, false, false)
        }

        // Guardrails:
        // - Only accept a cost if we see either an explicit "$" or a decimal with 2 digits.
        // - Reject unreasonably large values.
        let maxCents = 10_000_000

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        struct Candidate {
            let cents: Int
            let hadCurrency: Bool
            let hadDecimal: Bool
            let atLineEnd: Bool
            let location: Int
        }

        var candidates: [Candidate] = []

        func isASCIIAlphaNum(_ codeUnit: unichar) -> Bool {
            switch codeUnit {
            case 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let groupRange = match.range(at: 1)
            guard groupRange.location != NSNotFound, groupRange.length > 0 else { continue }

            // Avoid matching digits inside alphanumeric tokens (e.g., "XG7317").
            if groupRange.location > 0 {
                let prevChar = nsText.character(at: groupRange.location - 1)
                if isASCIIAlphaNum(prevChar) {
                    continue
                }
                if prevChar == 45, groupRange.location > 1 { // "-"
                    let prevPrev = nsText.character(at: groupRange.location - 2)
                    if isASCIIAlphaNum(prevPrev) {
                        continue
                    }
                }
            }
            if groupRange.location + groupRange.length < nsText.length {
                let nextChar = nsText.character(at: groupRange.location + groupRange.length)
                if isASCIIAlphaNum(nextChar) {
                    continue
                }
                if nextChar == 45, groupRange.location + groupRange.length + 1 < nsText.length { // "-"
                    let nextNext = nsText.character(at: groupRange.location + groupRange.length + 1)
                    if isASCIIAlphaNum(nextNext) {
                        continue
                    }
                }
            }

            let numeric = nsText.substring(with: groupRange)
                .replacingOccurrences(of: ",", with: "")

            let hadDecimal = numeric.contains(".")
            let cents: Int

            if hadDecimal {
                let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                guard let dollars = Int(parts[0]), let centPart = Int(parts[1]) else { continue }
                cents = dollars * 100 + centPart
            } else {
                guard let value = Int(numeric) else { continue }
                if value > 999 {
                    cents = value
                } else {
                    cents = value * 100
                }
            }

            let fullMatch = nsText.substring(with: match.range)
            let hadCurrency = fullMatch.contains("$")

            // Reduce false positives: ignore integers without currency and ignore overly large values.
            if !hadCurrency && !hadDecimal {
                continue
            }
            if cents < 0 || cents >= maxCents {
                continue
            }

            let afterIndex = match.range.location + match.range.length
            let suffix = afterIndex < nsText.length ? nsText.substring(from: afterIndex) : ""
            let atLineEnd = suffix.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) == nil

            candidates.append(Candidate(
                cents: cents,
                hadCurrency: hadCurrency,
                hadDecimal: hadDecimal,
                atLineEnd: atLineEnd,
                location: match.range.location
            ))
        }

        if let quantityHint, quantityHint > 1, !candidates.isEmpty {
            // When both unit and line-total values are present, prefer the unit value.
            let ascendingByAmount = candidates.sorted { $0.cents < $1.cents }
            for unitCandidate in ascendingByAmount where unitCandidate.cents > 0 {
                let expectedTotal = unitCandidate.cents * quantityHint
                if candidates.contains(where: { $0.cents == expectedTotal }) {
                    return (unitCandidate.cents, true, unitCandidate.hadCurrency)
                }
            }

            // Fallback for tabular OCR rows where unit price appears first.
            if let firstByLocation = candidates.min(by: { $0.location < $1.location }) {
                return (firstByLocation.cents, true, firstByLocation.hadCurrency)
            }
        }

        guard let best = candidates.sorted(by: { a, b in
            if a.hadCurrency != b.hadCurrency { return a.hadCurrency && !b.hadCurrency }
            if a.hadDecimal != b.hadDecimal { return a.hadDecimal && !b.hadDecimal }
            if a.atLineEnd != b.atLineEnd { return a.atLineEnd && !b.atLineEnd }
            if a.cents != b.cents { return a.cents > b.cents }
            return a.location > b.location
        }).first else {
            return (0, false, false)
        }

        return (best.cents, true, best.hadCurrency)
    }

    func extractPartNumber(from text: String) -> (value: String?, found: Bool) {
        if let regex = try? NSRegularExpression(pattern: partPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges >= 3,
               let r = Range(match.range(at: 2), in: text) {
                let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return (value, true)
                }
            }
        }

        // Fallback heuristic.
        let rawTokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        for raw in rawTokens {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            let token = raw.trimmingCharacters(in: allowed.inverted)
            guard token.count >= 4 else { continue }
            guard token.rangeOfCharacter(from: .letters) != nil else { continue }
            guard token.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
            guard token.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil else { continue } // not pure number
            return (token, true)
        }

        return (nil, false)
    }

    func cleanItemName(from firstLine: String, partNumber: String?, quantity: Int) -> String {
        var name = firstLine

        // Remove explicit part number labels.
        if let regex = try? NSRegularExpression(pattern: partPattern) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            name = regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "")
        }

        if let partNumber, !partNumber.isEmpty {
            name = name.replacingOccurrences(of: partNumber, with: "", options: [.caseInsensitive])
        }

        // Remove leading quantity.
        if let regex = try? NSRegularExpression(pattern: #"^\s*\d+\s+"#) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            name = regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "")
        }

        // Remove explicit qty markers.
        for pattern in qtyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                name = regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "")
            }
        }

        // Remove monetary tokens while preserving sizes such as "225/60/16".
        if let regex = try? NSRegularExpression(pattern: monetaryTokenPattern) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            name = regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "")
        }

        // As a last touch, remove "x{qty}" if present.
        let xQty = "x\(quantity)"
        name = name.replacingOccurrences(of: xQty, with: "", options: [.caseInsensitive])
        if quantity > 1 {
            let escapedQuantity = NSRegularExpression.escapedPattern(for: String(quantity))
            let qtySuffixPattern = "\\s+\(escapedQuantity)\\s*$"
            name = name.replacingOccurrences(of: qtySuffixPattern, with: "", options: .regularExpression)
        }

        name = name
            .replacingOccurrences(of: #"^[\s/|:;,\-]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return name
    }

    func normalizeDescriptions(_ items: [ParsedLineItem]) -> [ParsedLineItem] {
        items
            .map { item in
                var updated = item
                var description = updated.name
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if description.isEmpty,
                   let partNumber = updated.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !partNumber.isEmpty {
                    description = partNumber
                }

                updated.name = description
                return updated
            }
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func firstMonetaryTokenRange(in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: monetaryTokenPattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return matchRange
    }

    func shouldSwapDocumentIdentifiers(invoiceNumber: String?, poNumber: String?) -> Bool {
        guard let invoiceNumber = normalizedIdentifier(invoiceNumber),
              let poNumber = normalizedIdentifier(poNumber) else {
            return false
        }

        let invoiceUpper = invoiceNumber.uppercased()
        let poUpper = poNumber.uppercased()

        let invoiceLooksLikePO = invoiceUpper.hasPrefix("PO")
        let poLooksLikePO = poUpper.hasPrefix("PO")

        guard invoiceLooksLikePO, !poLooksLikePO else {
            return false
        }

        if poUpper.hasPrefix("INV")
            || poUpper.hasPrefix("MAP-")
            || poUpper.hasPrefix("BILL-")
            || poUpper.range(of: #"^[A-Z]{2,6}-\d{3,}$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizeIdentifierCandidate(_ candidate: String) -> String? {
        let value = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":#"))
            .replacingOccurrences(of: " ", with: "")

        guard !value.isEmpty else { return nil }
        let upper = value.uppercased()

        let disallowed = Set([
            "NO", "NUMBER", "INV", "INVOICE", "PO", "VENDOR", "DATE",
            "PHONE", "EMAIL", "BILL", "SHIP", "ACCOUNT", "CUSTOMER"
        ])
        guard !disallowed.contains(upper) else { return nil }
        guard upper.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }

        return value
    }

    func extractIdentifier(
        from text: String,
        inlinePatterns: [String],
        labelOnlyPattern: String
    ) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let inlineRegexes = inlinePatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        let labelOnlyRegex = try? NSRegularExpression(pattern: labelOnlyPattern)

        for index in lines.indices {
            let line = lines[index]
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)

            for regex in inlineRegexes {
                for match in regex.matches(in: line, options: [], range: lineRange) {
                    guard match.numberOfRanges > 1,
                          let captureRange = Range(match.range(at: 1), in: line) else {
                        continue
                    }

                    if let normalized = normalizeIdentifierCandidate(String(line[captureRange])) {
                        return normalized
                    }
                }
            }

            guard let labelOnlyRegex,
                  labelOnlyRegex.firstMatch(in: line, options: [], range: lineRange) != nil else {
                continue
            }

            var lookahead = lines.index(after: index)
            while lookahead < lines.count {
                let nextLine = lines[lookahead].trimmingCharacters(in: .whitespacesAndNewlines)
                if nextLine.isEmpty {
                    lookahead = lines.index(after: lookahead)
                    continue
                }

                if let normalized = normalizeIdentifierCandidate(nextLine) {
                    return normalized
                }
                break
            }
        }

        return nil
    }
}

private extension String {
    var containsVendorKeywords: Bool {
        let keywords = ["AUTO", "PARTS", "SUPPLY", "LLC", "INC", "MOTORS", "DISTRIBUTING"]
        let upper = self.uppercased()
        return keywords.contains(where: { upper.contains($0) })
    }
}
