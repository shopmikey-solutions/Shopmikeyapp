//
//  LocalParseHandoffService.swift
//  POScannerApp
//

import Foundation

struct ParseHandoffMetrics: Hashable {
    let rawLineCount: Int
    let deduplicatedLineCount: Int
    let ruleLineCount: Int
    let modelLineCount: Int
    let rawCharacterCount: Int
    let rulesCharacterCount: Int
    let modelCharacterCount: Int
    let rulesTrimmed: Bool
    let modelTrimmed: Bool
    let barcodeCount: Int
}

struct ParseHandoffPayload: Hashable {
    let rulesInputText: String
    let modelInputText: String
    let metrics: ParseHandoffMetrics

    var hasModelInput: Bool {
        modelInputText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 24
    }
}

/// Prepares OCR review text for local parsing.
///
/// The goal is to keep a full-fidelity rules input while producing a compact model input that
/// prioritizes high-signal rows (headers, item lines, prices, quantities, part numbers, barcodes).
final class LocalParseHandoffService: @unchecked Sendable {
    private let maxRulesCharacters: Int
    private let maxRulesLines: Int
    private let maxModelCharacters: Int
    private let maxModelLines: Int

    init(
        maxRulesCharacters: Int = 24_000,
        maxRulesLines: Int = 500,
        maxModelCharacters: Int = 8_000,
        maxModelLines: Int = 160
    ) {
        self.maxRulesCharacters = maxRulesCharacters
        self.maxRulesLines = maxRulesLines
        self.maxModelCharacters = maxModelCharacters
        self.maxModelLines = maxModelLines
    }

    func build(
        reviewedText: String,
        barcodeHints: [OCRService.DetectedBarcode]
    ) -> ParseHandoffPayload {
        let rawLines = splitNormalizedLines(from: reviewedText)
        let deduplicatedLines = deduplicate(lines: rawLines)
        let barcodeLines = normalizedBarcodeLines(from: barcodeHints)

        let allRulesLines = deduplicate(lines: deduplicatedLines + barcodeLines)
        let clampedRules = clamp(
            lines: allRulesLines,
            maxLines: maxRulesLines,
            maxCharacters: maxRulesCharacters
        )

        let candidateModelLines = prioritizedModelLines(from: deduplicatedLines)
        let combinedModelLines = deduplicate(lines: candidateModelLines + barcodeLines)
        let clampedModel = clamp(
            lines: combinedModelLines,
            maxLines: maxModelLines,
            maxCharacters: maxModelCharacters
        )

        let fallbackModelLines: [String]
        if clampedModel.lines.isEmpty {
            fallbackModelLines = Array(clampedRules.lines.prefix(64))
        } else {
            fallbackModelLines = clampedModel.lines
        }

        let rulesInputText = clampedRules.lines.joined(separator: "\n")
        let modelInputText = fallbackModelLines.joined(separator: "\n")

        return ParseHandoffPayload(
            rulesInputText: rulesInputText,
            modelInputText: modelInputText,
            metrics: ParseHandoffMetrics(
                rawLineCount: rawLines.count,
                deduplicatedLineCount: deduplicatedLines.count,
                ruleLineCount: clampedRules.lines.count,
                modelLineCount: fallbackModelLines.count,
                rawCharacterCount: reviewedText.count,
                rulesCharacterCount: rulesInputText.count,
                modelCharacterCount: modelInputText.count,
                rulesTrimmed: clampedRules.wasTrimmed,
                modelTrimmed: clampedModel.wasTrimmed,
                barcodeCount: barcodeLines.count
            )
        )
    }

    private func splitNormalizedLines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { normalizeWhitespace(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func normalizedBarcodeLines(from barcodes: [OCRService.DetectedBarcode]) -> [String] {
        barcodes
            .map { "[BARCODE \($0.symbology)] \($0.payload)" }
            .map(normalizeWhitespace)
            .filter { !$0.isEmpty }
    }

    private func deduplicate(lines: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for line in lines {
            let key = line.lowercased()
            if seen.insert(key).inserted {
                ordered.append(line)
            }
        }

        return ordered
    }

    private func prioritizedModelLines(from lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }

        struct ScoredLine {
            let index: Int
            let line: String
            let score: Int
        }

        let scored: [ScoredLine] = lines.enumerated().map { index, line in
            ScoredLine(index: index, line: line, score: scoreForModel(line: line))
        }

        var selectedIndices = Set<Int>()

        for entry in scored where entry.score >= 3 {
            selectedIndices.insert(entry.index)
            if entry.index > 0 { selectedIndices.insert(entry.index - 1) }
            if entry.index + 1 < lines.count { selectedIndices.insert(entry.index + 1) }
        }

        for entry in scored.prefix(8) where entry.score >= 1 {
            selectedIndices.insert(entry.index)
        }

        for entry in scored where isHeaderSignal(line: entry.line) && entry.score >= 2 {
            selectedIndices.insert(entry.index)
        }

        // Keep deterministic ordering as it appeared in OCR text.
        var selected = lines.indices
            .filter { selectedIndices.contains($0) }
            .map { lines[$0] }

        if selected.count < min(8, lines.count) {
            selected = Array(lines.prefix(min(lines.count, 80)))
        }

        return selected
    }

    private func scoreForModel(line: String) -> Int {
        var score = 0

        if isHeaderSignal(line: line) { score += 3 }
        if line.range(of: "\\$?\\s*\\d{1,3}(?:,\\d{3})*(?:\\.\\d{2})\\b", options: .regularExpression) != nil {
            score += 4
        }
        if line.range(of: "(?i)(qty|quantity)[:\\s]*\\d+", options: .regularExpression) != nil {
            score += 3
        }
        if line.range(of: "(?i)[A-Z]{1,6}-?[A-Z0-9]{2,}", options: .regularExpression) != nil {
            score += 2
        }
        if line.range(of: "\\b\\d{3}/\\d{2}/\\d{2}\\b|\\b\\d{3}/\\d{2}R?\\d{2}\\b", options: .regularExpression) != nil {
            score += 2
        }
        if line.localizedCaseInsensitiveContains("[BARCODE") { score += 4 }

        if isLowSignalLine(line: line) { score -= 3 }

        if line.count > 120,
           line.rangeOfCharacter(from: .decimalDigits) == nil,
           !isHeaderSignal(line: line) {
            score -= 2
        }

        return score
    }

    private func isHeaderSignal(line: String) -> Bool {
        let lower = line.lowercased()
        return Self.headerKeywords.contains { lower.contains($0) }
    }

    private func isLowSignalLine(line: String) -> Bool {
        let lower = line.lowercased()
        return Self.lowSignalKeywords.contains { lower.contains($0) }
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clamp(lines: [String], maxLines: Int, maxCharacters: Int) -> (lines: [String], wasTrimmed: Bool) {
        var collected: [String] = []
        var characterCount = 0

        for line in lines {
            let delimiterCost = collected.isEmpty ? 0 : 1
            let nextCost = delimiterCost + line.count
            let exceedsLineBudget = collected.count >= maxLines
            let exceedsCharBudget = (characterCount + nextCost) > maxCharacters

            if exceedsLineBudget || exceedsCharBudget {
                return (collected, true)
            }

            collected.append(line)
            characterCount += nextCost
        }

        return (collected, false)
    }

    private static let headerKeywords: Set<String> = [
        "invoice",
        "inv #",
        "po #",
        "po number",
        "purchase order",
        "vendor",
        "bill to",
        "ship to",
        "account",
        "terms",
        "due date",
        "invoice date"
    ]

    private static let lowSignalKeywords: Set<String> = [
        "remittance",
        "wire transfer",
        "terms and conditions",
        "thank you for your business",
        "payment instructions",
        "ach preferred"
    ]
}
