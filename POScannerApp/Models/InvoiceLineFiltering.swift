//
//  InvoiceLineFiltering.swift
//  POScannerApp
//

import Foundation

/// Currency-agnostic semantic filtering for OCR lines.
///
/// When `ignoreTax` is enabled, this removes non-product summary lines such as tax/subtotal/total rows.
/// It is intentionally conservative: SKU/product rows are preserved even if they contain words like "total".
func filterNonProductLines(_ lines: [String], ignoreTax: Bool) -> [String] {
    guard ignoreTax else { return lines }
    return lines.filter { !InvoiceLineClassifier.isNonProductSummaryLine($0) }
}

enum InvoiceLineClassifier {
    /// Returns true when a line is semantically a tax/subtotal/total summary row (not a product row).
    static func isNonProductSummaryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()

        // Freight/shipping can be a legitimate fee line, but "total amount due" variants are summary rows.
        if lower.contains("freight") || lower.contains("shipping") {
            // OCR often merges tax headers with shipping labels (e.g. "Tax (.%): Shipping:"); treat as summary.
            if lower.contains("tax") || lower.contains("vat") || lower.contains("gst") || lower.contains("hst") {
                return true
            }
            if lower.contains("total amount due")
                || lower.contains("amount due")
                || lower.contains("balance due")
                || lower.contains("grand total") {
                return true
            }
            return false
        }

        if isSubtotalLine(lower) {
            return true
        }

        if isTaxLine(lower) {
            return !isProbablyProductLine(trimmed)
        }

        if isTotalLine(lower) {
            return !isProbablyProductLine(trimmed)
        }

        return false
    }

    // MARK: - Summary detection

    private static func isSubtotalLine(_ lower: String) -> Bool {
        // Accept both "subtotal" and "sub total".
        if lower.range(of: #"^\s*sub\s*total\b"#, options: [.regularExpression]) != nil {
            return true
        }
        return false
    }

    private static func isTaxLine(_ lower: String) -> Bool {
        // Require a tax keyword plus some numeric signal (rate/amount).
        guard lower.range(of: #"\b(tax|vat|gst|hst)\b"#, options: [.regularExpression]) != nil else {
            return false
        }

        // Most tax lines include a rate or amount.
        let hasDigit = lower.rangeOfCharacter(from: .decimalDigits) != nil
        let hasPercent = lower.contains("%")
        return hasDigit || hasPercent
    }

    private static func isTotalLine(_ lower: String) -> Bool {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.range(of: #"^\s*grand\s+total\b"#, options: [.regularExpression]) != nil {
            return true
        }
        if trimmed.range(of: #"^\s*(total\s+due|amount\s+due|balance\s+due)\b"#, options: [.regularExpression]) != nil {
            return true
        }
        if trimmed.range(of: #"^\s*total\s*$"#, options: [.regularExpression]) != nil {
            return true
        }

        // Handle "Total <amount>" and "Total <currency> <amount>" style lines.
        guard trimmed.range(of: #"^\s*total\b"#, options: [.regularExpression]) != nil else {
            return false
        }

        // If the remainder after "total" contains "due"/"amount"/"balance", it's a summary line.
        if trimmed.range(of: #"\b(due|amount|balance|paid)\b"#, options: [.regularExpression]) != nil {
            return true
        }

        // If there are digits present and there are no non-currency alphabetic tokens after "total",
        // this is almost certainly a totals row (e.g. "Total USD 1,573.20").
        guard trimmed.rangeOfCharacter(from: .decimalDigits) != nil else {
            return false
        }

        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard tokens.count >= 2 else { return false }
        let restTokens = tokens.dropFirst()

        // If any token after "total" contains letters and is not a 3-letter currency code, treat it as non-summary.
        for token in restTokens {
            let lettersOnly = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard !lettersOnly.isEmpty else { continue }

            // Allow 3-letter currency codes like USD/EUR/CAD without hard-coding a list.
            if lettersOnly.count == 3, token.range(of: #"^[a-zA-Z]{3}$"#, options: [.regularExpression]) != nil {
                continue
            }
            return false
        }

        return true
    }

    // MARK: - Product heuristics

    private static func isProbablyProductLine(_ line: String) -> Bool {
        let lower = line.lowercased()

        // Quantity markers are strong signals for product rows.
        if lower.range(of: #"\b(qty|quantity)\b"#, options: [.regularExpression]) != nil {
            return true
        }
        if lower.range(of: #"\b\d+\s*(ea|pcs|pc|x)\b"#, options: [.regularExpression]) != nil {
            return true
        }

        // Part/SKU tokens that contain both letters and digits (e.g., "XG7317", "BP-123").
        if containsPartNumberLikeToken(line) {
            return true
        }

        return false
    }

    private static func containsPartNumberLikeToken(_ line: String) -> Bool {
        let rawTokens = line.split(whereSeparator: { $0.isWhitespace || $0.isNewline })

        for raw in rawTokens {
            let rawString = String(raw)

            // Exclude obvious tax rate tokens like "HST@13%" / "VAT20%".
            if rawString.range(of: #"(?i)^(tax|vat|gst|hst)[@]?\d{1,3}%?$"#, options: [.regularExpression]) != nil {
                continue
            }

            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            let token = rawString.trimmingCharacters(in: allowed.inverted)
            guard token.count >= 4 else { continue }
            guard token.rangeOfCharacter(from: .letters) != nil else { continue }
            guard token.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
            return true
        }

        return false
    }
}
