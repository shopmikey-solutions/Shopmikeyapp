//
//  POParser.swift
//  POScannerApp
//

import Foundation

/// Regex-based parser with basic confidence scoring.
///
/// - Important: Parsing is pure text -> model only. No Core Data, no networking, no shared state.
final class POParser: @unchecked Sendable {
    var decisionTraceEnabled = false
    var arithmeticDiagnosticsEnabled = false
    private(set) var latestDecisionTrace: POParseDecisionTrace?
    private(set) var latestArithmeticDiagnosticsReport: ParserArithmeticDiagnosticsReport?

    func parse(from text: String, ignoreTaxAndTotals: Bool = false) -> ParsedInvoice {
        let lines = nonEmptyLines(from: text)
        let headerLines = vendorHeaderCandidateLines(from: lines)

        let vendorName = extractVendorName(from: lines)
        let vendorPhone = extractVendorPhone(from: headerLines)
        let vendorEmail = extractVendorEmail(from: headerLines)

        var poNumber = extractPONumber(from: text)
        var invoiceNumber = extractInvoiceNumber(from: text)
        if shouldSwapDocumentIdentifiers(invoiceNumber: invoiceNumber, poNumber: poNumber) {
            swap(&poNumber, &invoiceNumber)
        }
        let traceRecorder = decisionTraceEnabled ? POParseDecisionTraceRecorder() : nil
        let items = extractLineItems(
            from: text,
            skippingFirstNonEmptyLine: vendorName != nil,
            vendorMatch: vendorName != nil,
            ignoreTaxAndTotals: ignoreTaxAndTotals,
            traceRecorder: traceRecorder
        )
        let normalizedItems = normalizeDescriptions(items)
        let totalCents = normalizedItems.reduce(0) { partial, item in
            partial + ((item.costCents ?? 0) * max(1, item.quantity ?? 1))
        }
        latestDecisionTrace = traceRecorder?.makeTrace()
        if arithmeticDiagnosticsEnabled {
            latestArithmeticDiagnosticsReport = arithmeticDiagnosticsReport(
                from: normalizedItems,
                computedSubtotalCents: totalCents,
                parsedTotalCents: totalCents > 0 ? totalCents : nil
            )
        } else {
            latestArithmeticDiagnosticsReport = nil
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
                vendorPhone: vendorPhone,
                vendorEmail: vendorEmail,
                vendorInvoiceNumber: invoiceNumber ?? "",
                poReference: poNumber ?? ""
            )
        )
    }

    private func arithmeticDiagnosticsReport(
        from items: [ParsedLineItem],
        computedSubtotalCents: Int,
        parsedTotalCents: Int?
    ) -> ParserArithmeticDiagnosticsReport {
        let zeroCostLineCount = items.reduce(into: 0) { count, item in
            if (item.costCents ?? 0) == 0 {
                count += 1
            }
        }
        let defaultedQuantityLineCount = items.reduce(into: 0) { count, item in
            if item.quantity == nil {
                count += 1
            }
        }
        let delta = computedSubtotalCents - (parsedTotalCents ?? computedSubtotalCents)

        return ParserArithmeticDiagnosticsReport(
            lineItemCount: items.count,
            computedSubtotalCents: computedSubtotalCents,
            parsedTotalCents: parsedTotalCents,
            totalDeltaCents: delta,
            zeroCostLineCount: zeroCostLineCount,
            defaultedQuantityLineCount: defaultedQuantityLineCount
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
                #"(?i)\bInv[ \t]*(?:No\.?|#|Number)?[ \t]*[:#]?[ \t]*([A-Z0-9][A-Z0-9\-]*)"#,
                #"(?i)\bOrder[ \t]*(?:No\.?|#|Number)?[ \t]*[:#]?[ \t]*([A-Z0-9][A-Z0-9\-]{3,})"#
            ],
            labelOnlyPattern: #"(?i)^\s*(Invoice|Inv|Order)[ \t]*(?:No\.?|#|Number)?[ \t]*[:#]?\s*$"#
        )
    }

    // MARK: - Line items

    private let qtyPatterns: [String] = [
        #"(?i)(qty|quantity)[:\s]*(\d+)"#,
        #"(?i)\b(\d+)\s*(qty|quantity)\b"#,
        #"(?i)\b(\d+)\s*(ea|pcs|x)\b"#,
        #"(?i)[\-–—]\s*(\d{1,3})\s*\+"#,
        #"(?i)\bx(\d+)\b"#
    ]

    private let costPattern: String = #"\$?\s?(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#
    private let monetaryTokenPattern: String = #"\$?\s*\d{1,3}(?:,\d{3})*\.\d{2}\b"#

    private let partPattern: String = #"(?i)(?:pn|p\/n|part(?:\s*(?:number|no\.?|#))?|sku)\s*[:#-]?\s*([A-Z0-9][A-Z0-9\-]{1,})"#

    private func extractLineItems(
        from text: String,
        skippingFirstNonEmptyLine: Bool,
        vendorMatch: Bool,
        ignoreTaxAndTotals: Bool,
        traceRecorder: POParseDecisionTraceRecorder? = nil
    ) -> [ParsedLineItem] {
        var lines = nonEmptyLines(from: text)
        if skippingFirstNonEmptyLine, !lines.isEmpty {
            lines.removeFirst()
        }

        // Currency-agnostic semantic filtering for tax/total lines when enabled.
        lines = filterNonProductLines(lines, ignoreTax: ignoreTaxAndTotals)

        let profile = documentProfile(for: lines)
        traceRecorder?.setChosenProfile(profile)
        if profile == .ecommerceCart {
            // Ecommerce cart screenshots commonly include "Part #" anchors and quantity steppers
            // with noisy pickup/promotional side panels.
            let anchorItems = extractEcommerceCartLineItems(from: lines, vendorMatch: vendorMatch)
            let stepperItems = extractStepperDrivenEcommerceLineItems(from: lines, vendorMatch: vendorMatch)
            let mergedItems = mergeEcommerceItems(primary: anchorItems, secondary: stepperItems)
            if mergedItems.count >= 2 {
                return mergedItems.filter(isValidParsedItem)
            }
            traceRecorder?.markFallbackTriggered()
        }

        var blocks: [[String]] = []
        var current: [String] = []

        for line in lines {
            if let traceRecorder {
                if let reason = ignorableLineReason(line) {
                    traceRecorder.recordRejectedLine(line, reason: reason)
                    continue
                }
            } else if isIgnorableLine(line) {
                continue
            }

            if InvoiceLineClassifier.isLaborServiceLine(line) {
                traceRecorder?.recordRejectedLine(line, reason: "laborServiceLine")
                continue
            }

            let attributeOnly = isAttributeOnlyLine(line)
            let nameLike = isNameLikeLine(line)

            if current.isEmpty {
                if attributeOnly {
                    traceRecorder?.recordRejectedLine(line, reason: "attributeOnlyWithoutContext")
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

extension POParser {
    enum DocumentProfile: String {
        case ecommerceCart
        case tabularInvoice
        case generic
    }

    func governanceDocumentProfile(for text: String) -> DocumentProfile {
        documentProfile(for: nonEmptyLines(from: text))
    }
}

private extension POParser {
    func documentProfile(for lines: [String]) -> DocumentProfile {
        Self.defaultDocumentProfileStrategy.resolveProfile(
            for: lines,
            hasStepperQuantityControlSignal: { self.hasStepperQuantityControlSignal(in: $0) },
            isEcommercePartAnchorLine: isEcommercePartAnchorLine,
            isLikelyEcommerceStatusLine: isLikelyEcommerceStatusLine,
            isTableHeaderLine: isTableHeaderLine,
            monetaryTokenCount: { self.allMonetaryTokenRanges(in: $0).count }
        )
    }

    func extractEcommerceCartLineItems(from lines: [String], vendorMatch: Bool) -> [ParsedLineItem] {
        let anchorIndices = lines.indices.filter { isEcommercePartAnchorLine(lines[$0]) }
        guard anchorIndices.count >= 2 else { return [] }

        let stepperIndices = lines.indices.filter { hasStepperQuantityControlSignal(in: lines[$0]) }

        var items: [ParsedLineItem] = []

        for (anchorOffset, anchorIndex) in anchorIndices.enumerated() {
            let previousAnchorIndex = anchorOffset > 0 ? anchorIndices[anchorOffset - 1] : nil
            let nextAnchorIndex = anchorOffset + 1 < anchorIndices.count ? anchorIndices[anchorOffset + 1] : lines.count

            var block: [String] = []
            var selectedIndices = Set<Int>()

            if let titleIndex = nearestEcommerceTitleIndex(
                before: anchorIndex,
                lowerBoundExclusive: previousAnchorIndex,
                lines: lines
            ) {
                block.append(lines[titleIndex])
                selectedIndices.insert(titleIndex)
            }

            block.append(lines[anchorIndex])
            selectedIndices.insert(anchorIndex)

            let quantityIndex = mappedEcommerceRowIndex(
                rowOffset: anchorOffset,
                rowCount: anchorIndices.count,
                candidateIndices: stepperIndices
            ) ?? nearestQuantityIndex(
                around: anchorIndex,
                lowerBoundExclusive: previousAnchorIndex,
                upperBoundExclusive: nextAnchorIndex,
                lines: lines
            )
            if let quantityIndex {
                block.append(lines[quantityIndex])
                selectedIndices.insert(quantityIndex)
            }

            let priceIndex = nearestPrimaryPriceIndex(
                around: anchorIndex,
                lowerBoundExclusive: previousAnchorIndex,
                upperBoundExclusive: nextAnchorIndex,
                lines: lines
            )
            if let priceIndex {
                block.append(lines[priceIndex])
                selectedIndices.insert(priceIndex)
            }

            if anchorIndex + 1 < nextAnchorIndex {
                for index in (anchorIndex + 1)..<nextAnchorIndex {
                    if selectedIndices.contains(index) { continue }
                    let line = lines[index]
                    if isLikelyEcommerceStatusLine(line) { continue }
                    if isLikelyEcommercePrimaryPriceLine(line) { continue }
                    if hasExplicitQuantitySignal(in: line)
                        || line.lowercased().localizedCaseInsensitiveHasPrefix("+ refundable core") {
                        block.append(line)
                    }
                }
            }

            var seenLines = Set<String>()
            let uniqueBlock = block.filter { seenLines.insert($0).inserted }
            guard !uniqueBlock.isEmpty else { continue }

            var parsed = parseItemBlock(uniqueBlock, vendorMatch: vendorMatch)
            if let quantityIndex {
                let quantity = extractQuantity(from: lines[quantityIndex])
                if quantity.found {
                    parsed.quantity = quantity.value
                }
            }
            if let priceIndex {
                let costProbeText: String
                if let quantityIndex {
                    costProbeText = "\(lines[priceIndex])\n\(lines[quantityIndex])"
                } else {
                    costProbeText = lines[priceIndex]
                }
                let lineCost = extractCost(
                    from: costProbeText,
                    quantityHint: parsed.quantity
                )
                if lineCost.found {
                    parsed.costCents = lineCost.cents
                }
            }
            if isValidParsedItem(parsed) {
                items.append(parsed)
            }
        }

        return items
    }

    func extractStepperDrivenEcommerceLineItems(from lines: [String], vendorMatch: Bool) -> [ParsedLineItem] {
        let stepperIndices = lines.indices.filter { hasStepperQuantityControlSignal(in: lines[$0]) }
        guard stepperIndices.count >= 1 else { return [] }

        var items: [ParsedLineItem] = []
        var seenSignatures = Set<String>()

        for (rowOffset, stepperIndex) in stepperIndices.enumerated() {
            let previousStepperIndex = rowOffset > 0 ? stepperIndices[rowOffset - 1] : nil
            let nextStepperIndex = rowOffset + 1 < stepperIndices.count ? stepperIndices[rowOffset + 1] : lines.count

            var block: [String] = []
            var selectedIndices = Set<Int>()

            if let titleIndex = nearestEcommerceTitleIndex(
                before: stepperIndex,
                lowerBoundExclusive: previousStepperIndex,
                lines: lines
            ) {
                block.append(lines[titleIndex])
                selectedIndices.insert(titleIndex)
            }

            if let anchorIndex = nearestEcommercePartAnchorIndex(
                around: stepperIndex,
                lowerBoundExclusive: previousStepperIndex,
                upperBoundExclusive: nextStepperIndex,
                lines: lines
            ) {
                block.append(lines[anchorIndex])
                selectedIndices.insert(anchorIndex)
            }

            block.append(lines[stepperIndex])
            selectedIndices.insert(stepperIndex)

            if let priceIndex = nearestPrimaryPriceIndex(
                around: stepperIndex,
                lowerBoundExclusive: previousStepperIndex,
                upperBoundExclusive: nextStepperIndex,
                lines: lines
            ) {
                block.append(lines[priceIndex])
                selectedIndices.insert(priceIndex)
            }

            var seenLines = Set<String>()
            let uniqueBlock = block.filter { seenLines.insert($0).inserted }
            guard !uniqueBlock.isEmpty else { continue }

            var parsed = parseItemBlock(uniqueBlock, vendorMatch: vendorMatch)
            let stepperQuantity = extractQuantity(from: lines[stepperIndex])
            if stepperQuantity.found {
                parsed.quantity = stepperQuantity.value
            }
            if let priceIndex = nearestPrimaryPriceIndex(
                around: stepperIndex,
                lowerBoundExclusive: previousStepperIndex,
                upperBoundExclusive: nextStepperIndex,
                lines: lines
            ) {
                let costProbeText = "\(lines[priceIndex])\n\(lines[stepperIndex])"
                let lineCost = extractCost(
                    from: costProbeText,
                    quantityHint: parsed.quantity
                )
                if lineCost.found {
                    parsed.costCents = lineCost.cents
                }
            }
            guard isValidParsedItem(parsed) else { continue }

            let signature = ecommerceItemSignature(for: parsed)
            if seenSignatures.insert(signature).inserted {
                items.append(parsed)
            }
        }

        return items
    }

    func nearestEcommercePartAnchorIndex(
        around stepperIndex: Int,
        lowerBoundExclusive: Int?,
        upperBoundExclusive: Int,
        lines: [String]
    ) -> Int? {
        let lowerBound = max(0, (lowerBoundExclusive ?? -1) + 1, stepperIndex - 5)
        let beforeUpperBound = min(lines.count, upperBoundExclusive, stepperIndex)
        guard lowerBound < beforeUpperBound else {
            return nil
        }

        // Prefer anchors that appear before the stepper to avoid borrowing the next row's part #.
        for index in stride(from: beforeUpperBound - 1, through: lowerBound, by: -1)
        where isEcommercePartAnchorLine(lines[index]) {
            return index
        }

        // Rare fallback: allow an immediate post-stepper anchor line only.
        let immediateAfterUpperBound = min(lines.count, upperBoundExclusive, stepperIndex + 2)
        if stepperIndex + 1 < immediateAfterUpperBound {
            for index in (stepperIndex + 1)..<immediateAfterUpperBound
            where isEcommercePartAnchorLine(lines[index]) {
                return index
            }
        }

        return nil
    }

    func ecommerceItemSignature(for item: ParsedLineItem) -> String {
        let normalizedName = item.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPart = (item.partNumber ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            normalizedName,
            normalizedPart,
            String(item.quantity ?? 1),
            String(item.costCents ?? 0)
        ].joined(separator: "|")
    }

    func ecommerceItemIdentityKey(for item: ParsedLineItem) -> String {
        let normalizedPart = (item.partNumber ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !normalizedPart.isEmpty {
            return "part:\(normalizedPart)"
        }
        let normalizedName = item.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "name:\(normalizedName)|qty:\(item.quantity ?? 1)"
    }

    func shouldPreferEcommerceItem(_ candidate: ParsedLineItem, over current: ParsedLineItem) -> Bool {
        let candidateHasPart = !(candidate.partNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let currentHasPart = !(current.partNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if candidateHasPart != currentHasPart {
            return candidateHasPart && !currentHasPart
        }

        let candidateHasCost = (candidate.costCents ?? 0) > 0
        let currentHasCost = (current.costCents ?? 0) > 0
        if candidateHasCost != currentHasCost {
            return candidateHasCost && !currentHasCost
        }

        if candidate.confidence != current.confidence {
            return candidate.confidence > current.confidence
        }

        return candidate.name.count > current.name.count
    }

    func mergeEcommerceItems(primary: [ParsedLineItem], secondary: [ParsedLineItem]) -> [ParsedLineItem] {
        var merged: [ParsedLineItem] = []
        var indexByKey: [String: Int] = [:]

        for item in primary + secondary {
            let key = ecommerceItemIdentityKey(for: item)
            if let existingIndex = indexByKey[key] {
                if shouldPreferEcommerceItem(item, over: merged[existingIndex]) {
                    merged[existingIndex] = item
                }
                continue
            }
            indexByKey[key] = merged.count
            merged.append(item)
        }

        return merged
    }

    func mappedEcommerceRowIndex(
        rowOffset: Int,
        rowCount: Int,
        candidateIndices: [Int]
    ) -> Int? {
        // Only rely on positional mapping when row cardinality matches exactly.
        // If counts diverge (for example, a cart row missing "Part #" anchor),
        // use proximity-based selection to avoid cross-row misalignment.
        guard candidateIndices.count == rowCount else { return nil }
        guard candidateIndices.indices.contains(rowOffset) else { return nil }
        return candidateIndices[rowOffset]
    }

    func nearestQuantityIndex(
        around anchorIndex: Int,
        lowerBoundExclusive: Int?,
        upperBoundExclusive: Int,
        lines: [String]
    ) -> Int? {
        let lowerBound = max(0, (lowerBoundExclusive ?? -1) + 1, anchorIndex - 3)
        let upperBound = min(lines.count, upperBoundExclusive, anchorIndex + 8)
        guard lowerBound < upperBound else { return nil }

        let candidates = (lowerBound..<upperBound)
            .filter { hasExplicitQuantitySignal(in: lines[$0]) }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            let lhsDistance = abs(lhs - anchorIndex)
            let rhsDistance = abs(rhs - anchorIndex)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            // Cart layouts place quantity controls after the part anchor most often.
            let lhsIsAfterAnchor = lhs >= anchorIndex
            let rhsIsAfterAnchor = rhs >= anchorIndex
            if lhsIsAfterAnchor != rhsIsAfterAnchor {
                return lhsIsAfterAnchor && !rhsIsAfterAnchor
            }

            return lhs < rhs
        }
    }

    func nearestPrimaryPriceIndex(
        around anchorIndex: Int,
        lowerBoundExclusive: Int?,
        upperBoundExclusive: Int,
        lines: [String]
    ) -> Int? {
        let searchLowerBound = max(0, (lowerBoundExclusive ?? -1) + 1, anchorIndex - 2)
        let searchUpperBound = min(lines.count, upperBoundExclusive + 2)
        guard searchLowerBound < searchUpperBound else { return nil }

        let candidates = (searchLowerBound..<searchUpperBound)
            .filter { index in
                index < lines.count && isLikelyEcommercePrimaryPriceLine(lines[index])
            }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            let lhsDistance = abs(lhs - anchorIndex)
            let rhsDistance = abs(rhs - anchorIndex)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            let lhsIsAfterAnchor = lhs >= anchorIndex
            let rhsIsAfterAnchor = rhs >= anchorIndex
            if lhsIsAfterAnchor != rhsIsAfterAnchor {
                return lhsIsAfterAnchor && !rhsIsAfterAnchor
            }

            return lhs < rhs
        }
    }

    func isLikelyEcommercePrimaryPriceLine(_ line: String) -> Bool {
        guard extractCost(from: line).found else { return false }
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }
        if isLikelyEcommerceStatusLine(lower) { return false }
        if isLikelyEcommerceCheckoutRailLine(lower) { return false }
        if lower.localizedCaseInsensitiveHasPrefix("+ refundable core") { return false }
        if lower.localizedCaseInsensitiveHasPrefix("reg.") { return false }
        if lower.localizedCaseInsensitiveHasPrefix("discount") { return false }
        if lower.contains("deal applied") { return false }
        if lower.contains("core charge") { return false }
        if lower.contains("gift certificate") || lower.contains("store credit") { return false }
        if InvoiceLineClassifier.isNonProductSummaryLine(lower) { return false }
        return true
    }

    func nearestEcommerceTitleIndex(
        before anchorIndex: Int,
        lowerBoundExclusive: Int?,
        lines: [String]
    ) -> Int? {
        guard anchorIndex > 0 else { return nil }
        let lowerBound = max(0, (lowerBoundExclusive ?? -1) + 1, anchorIndex - 6)
        for index in stride(from: anchorIndex - 1, through: lowerBound, by: -1) {
            let line = lines[index]
            if isLikelyEcommerceItemTitleLine(line) {
                return index
            }
        }
        return nil
    }

    func isLikelyEcommerceItemTitleLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isEcommercePartAnchorLine(trimmed) { return false }
        if isLikelyEcommerceStatusLine(trimmed) { return false }
        if isLikelyLegalOrComplianceNoiseLine(trimmed) { return false }
        if isLikelyEcommercePrimaryPriceLine(trimmed) { return false }
        if isAttributeOnlyLine(trimmed) { return false }
        if trimmed.lowercased().contains("warning:")
            || trimmed.lowercased().contains("p65warnings")
            || trimmed.lowercased().contains("defects, or other reproductive harm") {
            return false
        }
        if trimmed.range(of: #"^\d{4}\s+[A-Z0-9].*"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        if trimmed.range(of: #"(?i)\b(subaru|toyota|honda|ford|chevy|vehicle)\b"#, options: .regularExpression) != nil,
           !trimmed.contains("-") {
            return false
        }
        return trimmed.rangeOfCharacter(from: .letters) != nil
    }

    func isEcommercePartAnchorLine(_ line: String) -> Bool {
        line.range(
            of: #"(?i)\bpart\s*#\s*[A-Z0-9][A-Z0-9\-]{1,}\b"#,
            options: .regularExpression
        ) != nil
    }

    func isValidParsedItem(_ item: ParsedLineItem) -> Bool {
        let description = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return false
        }

        // Never surface legal/promo/status rows as editable line items.
        if isLikelyEcommerceStatusLine(description)
            || isLikelyLegalOrComplianceNoiseLine(description) {
            return false
        }

        if InvoiceLineClassifier.isHeaderArtifactLine(description) {
            return false
        }

        if InvoiceLineClassifier.isLaborServiceLine(description) {
            return false
        }

        let unitCents = item.costCents ?? 0
        let qty = max(1, item.quantity ?? 1)
        let totalCents = unitCents * qty
        let hasPartNumber = !(item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let zeroPriceSignalScore = self.zeroPriceProductSignalScore(description: description, item: item)

        // Zero-price ecommerce captures are valid when we still have strong product signals.
        if unitCents == 0 && totalCents == 0 {
            if !hasPartNumber && zeroPriceSignalScore < 2 {
                return false
            }
        }

        // Drop short ALL CAPS header-style rows only when no strong product evidence exists.
        if description == description.uppercased(),
           description.count < 25,
           unitCents == 0,
           !hasPartNumber,
           qty <= 1,
           zeroPriceSignalScore < 2 {
            return false
        }

        // Drop known summary labels.
        let upper = description.uppercased()
        let hardBannedKeywords = [
            "WAREHOUSE",
            "SUMMARY",
            "GIFT CERTIFICATE",
            "STORE CREDIT",
            "BALANCE DUE",
            "ORDER TOTAL",
            "TOTAL AMOUNT DUE"
        ]
        if hardBannedKeywords.contains(where: { upper.contains($0) }) {
            return false
        }

        // Treat financial summary labels as invalid rows unless the line looks product-like.
        let summaryKeywords = ParserNoiseTaxonomy.parserSummaryUpperKeywords
        if summaryKeywords.contains(where: { upper.contains($0) }) {
            if InvoiceLineClassifier.isNonProductSummaryLine(description) {
                return false
            }
            let hasStrongProductSignals = hasPartNumber
                || qty > 1
                || item.kind == .part
                || item.kind == .tire
            if !hasStrongProductSignals || !looksLikeProductRow(description, item: item) {
                return false
            }
        }

        return true
    }

    func zeroPriceProductSignalScore(description: String, item: ParsedLineItem) -> Int {
        let lower = description.lowercased()
        var score = 0

        if item.kind != .unknown && item.kindConfidence >= 0.55 {
            score += 1
        }
        if lower.range(of: #"\b(axle|clutch|flywheel|rotor|brake|pad|sensor|battery|filter|wheel|bearing|kit|tire)\b"#, options: .regularExpression) != nil {
            score += 1
        }
        if lower.range(of: #"\b(front|rear|left|right|premium|performance)\b"#, options: .regularExpression) != nil {
            score += 1
        }
        if description.range(of: #"(?i)[A-Z]{2,}\d[A-Z0-9-]{2,}"#, options: .regularExpression) != nil {
            score += 1
        }

        return score
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

    func ignorableLineReason(_ line: String) -> String? {
        guard isIgnorableLine(line) else { return nil }
        if InvoiceLineClassifier.isHeaderArtifactLine(line) {
            return "headerArtifactLine"
        }
        if isTableHeaderLine(line) {
            return "tableHeaderLine"
        }
        if InvoiceLineClassifier.isNonProductSummaryLine(line) {
            return "nonProductSummaryLine"
        }
        return "suppressedNoiseLine"
    }

    func isIgnorableLine(_ line: String) -> Bool {
        if InvoiceLineClassifier.isHeaderArtifactLine(line) { return true }
        if isTableHeaderLine(line) { return true }
        if isLikelyEcommerceCheckoutRailLine(line) { return true }

        // Always ignore non-product summary lines (tax/subtotal/total). These must never become items.
        if InvoiceLineClassifier.isNonProductSummaryLine(line) { return true }

        let lower = line.lowercased()
        if isLikelyLegalOrComplianceNoiseLine(line) { return true }
        if lower.localizedCaseInsensitiveHasPrefix("my cart") { return true }
        if lower == "print" { return true }
        if lower.localizedCaseInsensitiveHasPrefix("non vehicle specific") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("warning:") { return true }
        if lower.contains("http://") || lower.contains("https://") { return true }
        if lower.contains("www.") && lower.contains(".com") { return true }
        if lower.contains("rockauto.com/orderstatus") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("visit ") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("reg.") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("discount:") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("fits ") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("in stock") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("purchase of") { return true }
        if lower.contains("free pick up") || lower.contains("pick up today") { return true }
        if lower.contains("deliver by") { return true }
        if lower.contains("available within") { return true }
        if lower.contains("call store to order") { return true }
        if lower.contains("check other stores") { return true }
        if lower.contains("same day eligible") { return true }
        if lower.contains("same dayeligible") { return true }
        if lower.contains("deal applied") { return true }
        if lower.contains("in stock") && lower.contains("ready in") { return true }
        if lower.contains("p65warnings.ca.gov") { return true }
        if lower.contains("defects, or other reproductive harm") { return true }
        if lower.contains("remove"), !hasStepperQuantityControlSignal(in: line) { return true }
        if lower.contains("tap to expand") { return true }
        if lower == "info" { return true }
        if lower == "help" { return true }
        if lower == "cart" { return true }
        if lower == "menu" { return true }
        if lower == "order status & returns" { return true }
        if lower.contains("arrange a return") { return true }
        if lower.contains("report a problem") { return true }
        if lower.contains("return policy") { return true }
        if lower == "shipped" { return true }
        if lower.range(of: #"^\d{4}\s+[a-z0-9].*\b\d\.\d+l\b"#, options: .regularExpression) != nil { return true }
        if lower.hasPrefix("warehouse ") { return true }
        if lower.contains("tracking:") { return true }
        if lower.contains("cart menu") { return true }
        if lower.contains("order status") && lower.contains("returns") { return true }
        if lower.contains("parts catalog") || lower.contains("help pages") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("to check order status") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("please print this page as your receipt") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("order total") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("balance due") { return true }
        if lower.contains("gift certificate") || lower.contains("store credit") { return true }
        if lower.contains("all the parts your car will ever need") { return true }
        if lower.contains("pickup location") { return true }
        if (lower.contains("unit") && lower.contains("ext"))
            && (lower.contains("pickup location") || lower.contains("part #") || lower.contains("description")) {
            return true
        }
        if lower.contains("unit price") && lower.contains("extended") { return true }
        if lower.contains("purchase order") { return true }
        if lower.contains("invoice #:") && lower.contains("po number") { return true }
        if lower.contains("total amount due") { return true }
        if lower.contains("amount due") && lower.contains("$") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("po:") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("po #") { return true }
        if lower.localizedCaseInsensitiveHasPrefix("po no") { return true }
        return false
    }

    func isTableHeaderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        let headerTokens = [
            "qty",
            "quantity",
            "part",
            "part #",
            "description",
            "desc",
            "brand",
            "location",
            "pickup location",
            "unit",
            "ext",
            "amount",
            "price"
        ]
        let matchCount = headerTokens.filter { lower.contains($0) }.count
        if matchCount < 3 {
            return false
        }

        // Typical table headers are mostly words/symbols and contain little to no numeric content.
        let digitCount = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return digitCount <= 2
    }

    func vendorHeaderCandidateLines(from lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }

        var merged = Array(lines.prefix(16))
        let labeled = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("phone")
                || lower.contains("email")
                || lower.contains("contact")
                || lower.contains("@")
        }

        for line in labeled where !merged.contains(line) {
            merged.append(line)
        }
        return merged
    }

    func extractVendorEmail(from lines: [String]) -> String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        for line in lines {
            guard let match = firstRegexMatch(
                in: line,
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let cleaned = match
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    func extractVendorPhone(from lines: [String]) -> String? {
        let pattern = #"(?:\+?1[\s\-.]?)?(?:\(?\d{3}\)?[\s\-.]?)\d{3}[\s\-.]?\d{4}(?:\s*(?:ext|x)\s*\d{1,5})?"#
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("fax"), !lower.contains("phone") {
                continue
            }

            guard let match = firstRegexMatch(
                in: line,
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let cleaned = match
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if cleaned.count >= 10 {
                return cleaned
            }
        }
        return nil
    }

    func firstRegexMatch(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    func isAttributeOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Cart steppers (e.g. "- 6 + REMOVE") carry quantity but not product description.
        if hasStepperQuantityControlSignal(in: trimmed) {
            return true
        }

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
        if looksLikeContinuationLine(line, currentBlock: currentBlock) {
            return false
        }
        if isAttributeOnlyLine(line) {
            return false
        }
        if isLikelyEcommerceStatusLine(line) {
            return false
        }

        let currentText = currentBlock.joined(separator: "\n")
        let currentHasCost = extractCost(from: currentText).found
        let currentHasPart = extractPartNumber(from: currentText).found
        let currentHasQuantity = hasExplicitQuantitySignal(in: currentText)

        let lineHasCost = extractCost(from: line).found
        let lineHasPart = extractPartNumber(from: line).found
        let lineHasQuantity = hasExplicitQuantitySignal(in: line)

        if currentBlock.count >= 4 {
            return true
        }

        if lineHasPart && currentHasPart {
            return true
        }
        if lineHasCost && currentHasCost {
            return true
        }
        if lineHasQuantity && currentHasQuantity {
            return true
        }
        if currentBlock.count >= 2 && (lineHasPart || lineHasCost || lineHasQuantity) {
            return true
        }

        _ = line
        return false
    }

    func looksLikeContinuationLine(_ line: String, currentBlock: [String]) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if hasExplicitQuantitySignal(in: trimmed) { return false }
        if extractPartNumber(from: trimmed).found { return false }
        if extractCost(from: trimmed).found { return false }

        if trimmed.hasPrefix("(") {
            return true
        }

        // Multi-line ecommerce cards frequently split name/model/details across adjacent lines.
        return currentBlock.count <= 2
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
            guard !isLikelyEcommerceStatusLine(trimmed) else { return false }
            guard !InvoiceLineClassifier.isNonProductSummaryLine(trimmed) else { return false }
            guard !InvoiceLineClassifier.isHeaderArtifactLine(trimmed) else { return false }
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
        let lower = line.lowercased()
        var score = (letters * 5) + line.count - (digits * 2)

        if line.range(of: #"(?i)[A-Z]{1,8}[A-Z0-9-]*\d[A-Z0-9-]{1,}"#, options: .regularExpression) != nil {
            score += 40
        }
        if line.range(of: monetaryTokenPattern, options: .regularExpression) != nil {
            score += 15
        }
        if lower.contains("rockauto") && lower.contains("order confirmation") {
            score -= 80
        }
        if lower.contains("http://")
            || lower.contains("https://")
            || (lower.contains("www.") && lower.contains(".com"))
            || lower.localizedCaseInsensitiveHasPrefix("visit ") {
            score -= 160
        }
        if lower.localizedCaseInsensitiveHasPrefix("part #") {
            score -= 110
        }
        if isLikelyEcommerceStatusLine(line) {
            score -= 180
        }
        if lower == "info"
            || lower.contains("tracking:")
            || lower.contains("warehouse ")
            || lower.contains("order status & returns")
            || lower.contains("cart menu")
            || lower.contains("arrange a return")
            || lower.contains("report a problem")
            || lower.contains("tap to expand") {
            score -= 120
        }
        if lower.range(of: #"^\d{4}\s+[a-z0-9].*\b\d\.\d+l\b"#, options: .regularExpression) != nil {
            score -= 100
        }

        return score
    }

    func extractQuantity(from text: String) -> (value: Int, found: Bool) {
        for pattern in qtyPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { continue }

            let groupIndexes = Array(1..<match.numberOfRanges).reversed()
            for groupIndex in groupIndexes {
                guard let r = Range(match.range(at: groupIndex), in: text) else { continue }
                if let value = Int(text[r]), value >= 1 {
                    return (value, true)
                }
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

        // Additional table fallback: quantity often sits between two money columns.
        let monetaryRanges = allMonetaryTokenRanges(in: text)
        if monetaryRanges.count >= 2 {
            for index in 0..<(monetaryRanges.count - 1) {
                let between = text[monetaryRanges[index].upperBound..<monetaryRanges[index + 1].lowerBound]
                let candidateTokens = between
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)

                for token in candidateTokens.reversed() {
                    if let value = Int(token), (1...200).contains(value) {
                        return (value, true)
                    }
                }
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

            let contextStart = max(0, match.range.location - 24)
            let contextRange = NSRange(location: contextStart, length: match.range.location - contextStart)
            let leadingContext = nsText.substring(with: contextRange).lowercased()

            // Suppress ecommerce checkout-rail prices (subtotal/est total/promo summary)
            // so they are never treated as item-level costs.
            let windowStart = max(0, match.range.location - 48)
            let windowEnd = min(nsText.length, match.range.location + match.range.length + 48)
            let windowRange = NSRange(location: windowStart, length: windowEnd - windowStart)
            let candidateWindow = nsText.substring(with: windowRange)
            if isLikelyEcommerceCheckoutRailLine(candidateWindow) {
                continue
            }

            // Reduce false positives: ignore integers without currency and ignore overly large values.
            if !hadCurrency && !hadDecimal {
                continue
            }
            if leadingContext.contains("reg.")
                || leadingContext.hasSuffix("reg")
                || leadingContext.contains("discount")
                || leadingContext.contains("deal applied")
                || leadingContext.contains("refundable core")
                || leadingContext.contains("core charge") {
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

            // Ecommerce cart rows often show only line totals with a stepper quantity control.
            if candidates.count == 1, hasStepperQuantityControlSignal(in: text) {
                let candidate = candidates[0]
                if candidate.cents > 0 {
                    let exactUnit = Double(candidate.cents) / Double(quantityHint)
                    let roundedUnit = Int(exactUnit.rounded())
                    if roundedUnit > 0 {
                        return (roundedUnit, true, candidate.hadCurrency)
                    }
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
        var explicitPartNumber: String?
        if let regex = try? NSRegularExpression(pattern: partPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: text) {
                let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    explicitPartNumber = value
                }
            }
        }

        if let suggested = LineItemSuggestionService.preferredPartNumber(
            from: text,
            explicitPartNumber: explicitPartNumber
        ) {
            return (suggested, true)
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

        name = name.replacingOccurrences(
            of: #"(?i)\bline\s+[A-Z0-9]{2,6}\b"#,
            with: "",
            options: .regularExpression
        )

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

        name = name.replacingOccurrences(
            of: #"(?i)[\-–—]\s*\d{1,3}\s*\+\s*remove\b"#,
            with: "",
            options: .regularExpression
        )
        name = name.replacingOccurrences(
            of: #"(?i)\bremove\b"#,
            with: "",
            options: .regularExpression
        )
        name = name.replacingOccurrences(
            of: #"(?i)\b(?:free pick up|pick up today|deliver by|available within|call store to order|check other stores|same day eligible|deal applied)\b"#,
            with: "",
            options: .regularExpression
        )
        name = name.replacingOccurrences(
            of: #"(?i)\b(?:item subtotal|cart summary|total discounts|est\.?\s*total|continue to checkout|available payment methods(?: in checkout)?|apply promo code|code apply|pay with)\b"#,
            with: "",
            options: .regularExpression
        )

        // Remove common screenshot UI artifacts.
        name = name.replacingOccurrences(
            of: #"\binfo\b"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

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

    func allMonetaryTokenRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: monetaryTokenPattern) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        return matches.compactMap { match in
            Range(match.range, in: text)
        }
    }

    func hasExplicitQuantitySignal(in text: String) -> Bool {
        if hasStepperQuantityControlSignal(in: text) {
            return true
        }
        return text.range(
            of: #"\b(qty|quantity|x\d+|\d+\s*(ea|pcs|pc|qty|quantity|x))\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    func hasStepperQuantityControlSignal(in text: String) -> Bool {
        text.range(
            of: #"(?i)(?:^|\s)[\-–—]\s*\d{1,3}\s*\+"#,
            options: .regularExpression
        ) != nil
    }

    func isLikelyEcommerceStatusLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }
        if isLikelyEcommerceCheckoutRailLine(lower) { return true }
        if isLikelyLegalOrComplianceNoiseLine(lower) { return true }
        if ParserNoiseTaxonomy.ecommerceStatusPrefixKeywords.contains(where: { lower.localizedCaseInsensitiveHasPrefix($0) }) {
            return true
        }
        if ParserNoiseTaxonomy.ecommerceStatusContainsKeywords.contains(where: { lower.contains($0) }) {
            return true
        }
        if lower.contains("in stock") && lower.contains("ready in") { return true }
        if lower.contains("p65warnings.ca.gov") { return true }
        if lower.contains("defects, or other reproductive harm") { return true }
        if lower.contains("warning") && lower.contains("chemicals known") { return true }
        if lower.contains("remove") && !hasStepperQuantityControlSignal(in: line) { return true }
        return false
    }

    func isLikelyEcommerceCheckoutRailLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }

        if ParserNoiseTaxonomy.ecommerceCheckoutRailContainsKeywords.contains(where: { lower.contains($0) }) {
            return true
        }

        if lower.range(
            of: #"\b(subtotal|discount|est\.?\s*total|checkout|promo|payment methods|shipping estimates)\b"#,
            options: .regularExpression
        ) != nil,
           lower.range(of: #"\$\s*\d"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    func isLikelyLegalOrComplianceNoiseLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }

        if ParserNoiseTaxonomy.legalComplianceContainsKeywords.contains(where: { lower.contains($0) }) {
            return true
        }
        if lower.contains(ParserNoiseTaxonomy.legalComplianceInfoPairKeywords.trigger)
            && ParserNoiseTaxonomy.legalComplianceInfoPairKeywords.secondary.contains(where: { lower.contains($0) }) {
            return true
        }
        if lower.localizedCaseInsensitiveHasPrefix("please print this page as your receipt") {
            return true
        }
        if ParserNoiseTaxonomy.legalComplianceOrderStatusPairKeywords.contains(where: { lower.contains($0) })
            && lower.contains(ParserNoiseTaxonomy.legalComplianceOrderStatusSecondaryKeyword) {
            return true
        }

        return false
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

    func extractVendorName(from lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }

        for line in lines.prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lower = trimmed.lowercased()
            if lower.contains("rockauto") {
                return "RockAuto"
            }
            if lower.contains("order confirmation") || lower.contains("ship to:") || lower.contains("bill to:") {
                continue
            }

            if trimmed.containsVendorKeywords {
                return trimmed
            }
        }

        return nil
    }
}

private extension POParser {
    static let defaultDocumentProfileStrategy = DefaultDocumentProfileStrategy()
}

extension POParser {
    static var governanceStatusPrefixKeywords: [String] {
        ParserNoiseTaxonomy.ecommerceStatusPrefixKeywords
    }

    static var governanceStatusContainsKeywords: [String] {
        ParserNoiseTaxonomy.ecommerceStatusContainsKeywords
    }

    static var governanceLegalContainsKeywords: [String] {
        ParserNoiseTaxonomy.legalComplianceContainsKeywords
    }
}

private extension String {
    var containsVendorKeywords: Bool {
        let keywords = ["AUTO", "PARTS", "SUPPLY", "LLC", "INC", "MOTORS", "DISTRIBUTING"]
        let upper = self.uppercased()
        return keywords.contains(where: { upper.contains($0) })
    }
}
