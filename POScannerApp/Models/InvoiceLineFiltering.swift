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
    /// Returns true for OCR artifacts that represent table header metadata rather than item rows.
    static func isHeaderArtifactLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if lower.contains("pickup location") {
            return true
        }

        let hasPickupHeaderSignal = lower.contains("pickup location")
        let hasUnitHeaderSignal = lower.contains("unit ($)")
            || lower.contains("unit price")
            || lower.contains("unit cost")
        let hasExtendedHeaderSignal = lower.contains("ext ($)")
            || lower.contains("extended")
            || lower.contains("ext price")
        if hasPickupHeaderSignal && hasUnitHeaderSignal && hasExtendedHeaderSignal {
            return true
        }

        let headerTokens = [
            "qty",
            "quantity",
            "part #",
            "description",
            "brand",
            "unit",
            "ext",
            "amount",
            "price",
            "location"
        ]
        let tokenMatches = headerTokens.filter { lower.contains($0) }.count
        guard tokenMatches >= 3 else { return false }

        // If no concrete currency amount or SKU token exists, this is almost always a header artifact.
        let hasCurrencyValue = lower.range(
            of: #"\$\s*\d|\d{1,3}(?:,\d{3})*\.\d{2}"#,
            options: [.regularExpression]
        ) != nil
        if hasCurrencyValue {
            return false
        }

        return !containsPartNumberLikeToken(trimmed)
    }

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

    /// Returns true when a line appears to be a labor/service charge row that should not be posted
    /// as a parts/tire/fee inventory line item.
    static func isLaborServiceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if isNonProductSummaryLine(trimmed) {
            return false
        }

        let hasLaborKeyword = lower.range(
            of: #"\b(labor|labour|technician|mechanic|alignment service|diagnostic service|service labor|labor charge|labor rate)\b"#,
            options: [.regularExpression]
        ) != nil
        if hasLaborKeyword {
            return true
        }

        if lower.range(of: #"\b\d+(?:\.\d+)?\s*(hr|hrs|hour|hours)\b"#, options: [.regularExpression]) != nil {
            return true
        }

        // Keep explicit fee-like rows; these are valid for PO intake.
        let feeSignals = [
            "fee",
            "shop-fee",
            "shop fee",
            "env-fee",
            "env fee",
            "disposal",
            "disposal fee",
            "hazmat",
            "environmental",
            "environmental charge",
            "shop supplies",
            "shipping",
            "freight",
            "core",
            "core charge",
            "surcharge",
            "mount",
            "balance"
        ]
        if feeSignals.contains(where: { lower.contains($0) }) {
            return false
        }

        let hasServiceKeyword = lower.range(of: #"\bservice\b"#, options: [.regularExpression]) != nil
        let laborActionSignal = lower.range(
            of: #"\b(alignment|diagnostic|diagnostics|install(?:ation)?|program(?:ming)?|calibration|inspection|repair)\b"#,
            options: [.regularExpression]
        ) != nil
        if hasServiceKeyword && laborActionSignal {
            return true
        }

        let hasRateSignal = lower.range(of: #"\b(rate|labor rate|lab)\b"#, options: [.regularExpression]) != nil
        let hasDollarAmount = lower.range(of: #"\$\s*\d"#, options: [.regularExpression]) != nil
        if hasServiceKeyword && hasRateSignal && hasDollarAmount {
            return true
        }

        // Catch common labor rows even if "service" is omitted.
        if lower.range(
            of: #"\b(alignment|diagnostic|diagnostics|install(?:ation)?|program(?:ming)?|calibration|inspection|repair)\b"#,
            options: [.regularExpression]
        ) != nil,
           lower.range(of: #"\$\s*\d"#, options: [.regularExpression]) != nil {
            return true
        }

        // If the row still looks like a concrete purchasable part/tire line, keep it.
        if containsPartNumberLikeToken(trimmed) {
            return false
        }
        if lower.range(
            of: #"\b\d{3}/\d{2,3}(?:/\d{2}|(?:zr|r|-)?\d{2})\b"#,
            options: [.regularExpression]
        ) != nil {
            return false
        }
        if lower.range(
            of: #"\b(part|battery|filter|rotor|pad|sensor|hub|bearing|wiper|coil|coolant|gasket|fluid)\b"#,
            options: [.regularExpression]
        ) != nil {
            return false
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
            if token.range(of: #"(?i)^\d+-?(wheel|wheels|hour|hours|hr|hrs)$"#, options: [.regularExpression]) != nil {
                continue
            }
            guard token.rangeOfCharacter(from: .letters) != nil else { continue }
            guard token.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
            return true
        }

        return false
    }
}
