import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreParsing
@testable import POScannerApp

enum MetricField: String, CaseIterable, Codable {
    case sku
    case quantity
    case unitPrice
    case extendedPrice
    case lineType
    case documentIdentifier

    var label: String {
        switch self {
        case .sku:
            return "SKU"
        case .quantity:
            return "Quantity"
        case .unitPrice:
            return "Unit Price"
        case .extendedPrice:
            return "Extended Price"
        case .lineType:
            return "Line Type"
        case .documentIdentifier:
            return "Document ID"
        }
    }
}

struct FieldMatch: Codable, Equatable {
    var truePositive: Int = 0
    var falsePositive: Int = 0
    var falseNegative: Int = 0

    var precision: Double {
        let denominator = truePositive + falsePositive
        guard denominator > 0 else { return 0 }
        return Double(truePositive) / Double(denominator)
    }

    var recall: Double {
        let denominator = truePositive + falseNegative
        guard denominator > 0 else { return 0 }
        return Double(truePositive) / Double(denominator)
    }

    var f1: Double {
        let p = precision
        let r = recall
        guard p + r > 0 else { return 0 }
        return (2 * p * r) / (p + r)
    }

    mutating func add(_ other: FieldMatch) {
        truePositive += other.truePositive
        falsePositive += other.falsePositive
        falseNegative += other.falseNegative
    }

    mutating func add(expected: String?, actual: String?) {
        let normalizedExpected = ParserMetricsEvaluator.normalize(expected)
        let normalizedActual = ParserMetricsEvaluator.normalize(actual)
        add(expectedPresent: normalizedExpected != nil, actualPresent: normalizedActual != nil, valuesMatch: normalizedExpected == normalizedActual)
    }

    mutating func add(expected: Int?, actual: Int?) {
        add(expectedPresent: expected != nil, actualPresent: actual != nil, valuesMatch: expected == actual)
    }

    mutating func add(expectedPresent: Bool, actualPresent: Bool, valuesMatch: Bool) {
        switch (expectedPresent, actualPresent) {
        case (true, true):
            if valuesMatch {
                truePositive += 1
            } else {
                falsePositive += 1
                falseNegative += 1
            }
        case (true, false):
            falseNegative += 1
        case (false, true):
            falsePositive += 1
        case (false, false):
            break
        }
    }
}

struct CaseMetrics: Codable {
    var caseId: String
    var profile: String
    var fieldMatches: [MetricField: FieldMatch]

    var overall: FieldMatch {
        var combined = FieldMatch()
        for field in MetricField.allCases {
            if let match = fieldMatches[field] {
                combined.add(match)
            }
        }
        return combined
    }
}

struct AggregateMetrics: Codable {
    var cases: [CaseMetrics]
    var fieldMatches: [MetricField: FieldMatch]

    var overall: FieldMatch {
        var combined = FieldMatch()
        for field in MetricField.allCases {
            if let match = fieldMatches[field] {
                combined.add(match)
            }
        }
        return combined
    }
}

struct ParserMetricsOutputs {
    var markdownPath: URL
    var jsonPath: URL
}

enum ParserMetricsEvaluatorError: LocalizedError {
    case missingGolden(caseId: String, path: String)
    case unreadableGolden(caseId: String, path: String, underlying: Error)
    case invalidGolden(caseId: String, path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingGolden(let caseId, let path):
            return "Missing parser golden for \(caseId): \(path). Run: bash scripts/update_parser_goldens.sh"
        case .unreadableGolden(let caseId, let path, let underlying):
            return "Could not read parser golden for \(caseId) at \(path): \(underlying.localizedDescription)"
        case .invalidGolden(let caseId, let path, let underlying):
            return "Invalid parser golden JSON for \(caseId) at \(path): \(underlying.localizedDescription)"
        }
    }
}

enum ParserMetricsEvaluator {
    private struct GoldenSnapshot: Decodable {
        struct Document: Decodable {
            var vendorName: String?
            var poNumber: String?
            var invoiceNumber: String?
        }

        struct LineItem: Decodable {
            var description: String
            var partNumber: String?
            var quantity: Int?
            var unitPriceCents: Int?
            var extendedPriceCents: Int?
            var type: String
        }

        var caseId: String
        var profile: String
        var document: Document
        var lineItems: [LineItem]
    }

    private struct ActualSnapshot {
        struct LineItem {
            var description: String
            var partNumber: String?
            var quantity: Int?
            var unitPriceCents: Int?
            var extendedPriceCents: Int?
            var type: String
        }

        var documentIdentifier: String?
        var lineItems: [LineItem]
    }

    static func evaluate(fixtures: [ParserFixtureCase]) throws -> AggregateMetrics {
        let parser = POParser()
        var caseMetrics: [CaseMetrics] = []
        var aggregateByField = Dictionary(uniqueKeysWithValues: MetricField.allCases.map { ($0, FieldMatch()) })

        for fixture in fixtures.sorted(by: { $0.caseId < $1.caseId }) {
            let expected = try loadGolden(caseId: fixture.caseId)
            let parsed = parser.parse(from: fixture.rawText)
            let actual = snapshot(from: parsed)
            let perField = compare(expected: expected, actual: actual)

            for field in MetricField.allCases {
                aggregateByField[field]?.add(perField[field] ?? FieldMatch())
            }

            caseMetrics.append(
                CaseMetrics(
                    caseId: fixture.caseId,
                    profile: fixture.profile.rawValue,
                    fieldMatches: perField
                )
            )
        }

        return AggregateMetrics(cases: caseMetrics, fieldMatches: aggregateByField)
    }

    static func writeReports(metrics: AggregateMetrics) throws -> ParserMetricsOutputs {
        let reportDirectory = defaultReportDirectory()
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

        let markdownURL = reportDirectory.appendingPathComponent("parser_metrics_report.md", isDirectory: false)
        let jsonURL = reportDirectory.appendingPathComponent("parser_metrics_report.json", isDirectory: false)

        let markdown = renderMarkdown(metrics: metrics)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metrics)
        try data.write(to: jsonURL, options: .atomic)

        return ParserMetricsOutputs(markdownPath: markdownURL, jsonPath: jsonURL)
    }

    static func parseThreshold(from environment: [String: String] = ProcessInfo.processInfo.environment) -> Double? {
        if let value = parseThresholdValue(environment["PARSER_METRICS_MIN_F1"]) {
            return value
        }

        if let overridePath = environment["PARSER_METRICS_MIN_F1_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty,
           let value = parseThresholdValue((try? String(contentsOfFile: overridePath, encoding: .utf8))) {
            return value
        }

        let defaultThresholdPath = defaultReportDirectory().appendingPathComponent("parser_metrics_min_f1.txt", isDirectory: false)
        if let value = parseThresholdValue(try? String(contentsOf: defaultThresholdPath, encoding: .utf8)) {
            return value
        }

        return nil
    }

    private static func parseThresholdValue(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return Double(raw)
    }

    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func loadGolden(caseId: String) throws -> GoldenSnapshot {
        let goldenURL = goldenRootDirectory().appendingPathComponent("\(caseId).json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            throw ParserMetricsEvaluatorError.missingGolden(caseId: caseId, path: goldenURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: goldenURL)
        } catch {
            throw ParserMetricsEvaluatorError.unreadableGolden(caseId: caseId, path: goldenURL.path, underlying: error)
        }

        do {
            return try JSONDecoder().decode(GoldenSnapshot.self, from: data)
        } catch {
            throw ParserMetricsEvaluatorError.invalidGolden(caseId: caseId, path: goldenURL.path, underlying: error)
        }
    }

    private static func snapshot(from parsed: ParsedInvoice) -> ActualSnapshot {
        let documentIdentifier = firstNonEmpty(parsed.invoiceNumber, parsed.poNumber)
        let rows = parsed.items.map { item in
            let normalizedType = normalize(item.kind.rawValue) ?? "unknown"
            let extendedPrice: Int?
            if let quantity = item.quantity, let unitPrice = item.costCents {
                extendedPrice = quantity * unitPrice
            } else {
                extendedPrice = nil
            }

            return ActualSnapshot.LineItem(
                description: item.name,
                partNumber: item.partNumber,
                quantity: item.quantity,
                unitPriceCents: item.costCents,
                extendedPriceCents: extendedPrice,
                type: normalizedType
            )
        }

        return ActualSnapshot(documentIdentifier: documentIdentifier, lineItems: rows)
    }

    private static func compare(expected: GoldenSnapshot, actual: ActualSnapshot) -> [MetricField: FieldMatch] {
        var metrics = Dictionary(uniqueKeysWithValues: MetricField.allCases.map { ($0, FieldMatch()) })

        let expectedDocId = firstNonEmpty(expected.document.invoiceNumber, expected.document.poNumber)
        metrics[.documentIdentifier]?.add(expected: expectedDocId, actual: actual.documentIdentifier)

        alignRows(expected: expected.lineItems, actual: actual.lineItems) { expectedRow, actualRow in
            metrics[.sku]?.add(expected: expectedRow?.partNumber, actual: actualRow?.partNumber)
            metrics[.quantity]?.add(expected: expectedRow?.quantity, actual: actualRow?.quantity)
            metrics[.unitPrice]?.add(expected: expectedRow?.unitPriceCents, actual: actualRow?.unitPriceCents)
            metrics[.extendedPrice]?.add(expected: expectedRow?.extendedPriceCents, actual: actualRow?.extendedPriceCents)
            metrics[.lineType]?.add(expected: expectedRow?.type, actual: actualRow?.type)
        }

        return metrics
    }

    private static func alignRows(
        expected: [GoldenSnapshot.LineItem],
        actual: [ActualSnapshot.LineItem],
        consume: (GoldenSnapshot.LineItem?, ActualSnapshot.LineItem?) -> Void
    ) {
        let expectedBuckets = Dictionary(grouping: expected) { lineKey(description: $0.description, partNumber: $0.partNumber) }
        let actualBuckets = Dictionary(grouping: actual) { lineKey(description: $0.description, partNumber: $0.partNumber) }
        let orderedKeys = Set(expectedBuckets.keys).union(actualBuckets.keys).sorted()

        for key in orderedKeys {
            let expectedRows = expectedBuckets[key] ?? []
            let actualRows = actualBuckets[key] ?? []
            let count = max(expectedRows.count, actualRows.count)

            for index in 0..<count {
                let expectedRow = index < expectedRows.count ? expectedRows[index] : nil
                let actualRow = index < actualRows.count ? actualRows[index] : nil
                consume(expectedRow, actualRow)
            }
        }
    }

    private static func lineKey(description: String, partNumber: String?) -> String {
        if let normalizedPart = normalize(partNumber) {
            return "sku:\(normalizedPart)"
        }

        if let normalizedDescription = normalize(description) {
            return "desc:\(normalizedDescription)"
        }

        return "unknown"
    }

    private static func renderMarkdown(metrics: AggregateMetrics) -> String {
        var lines: [String] = []
        lines.append("# Parser Metrics Report")
        lines.append("")
        lines.append("## Aggregate Field Metrics")
        lines.append("")
        lines.append("| Field | Precision | Recall | F1 | TP | FP | FN |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|")

        for field in MetricField.allCases {
            let match = metrics.fieldMatches[field] ?? FieldMatch()
            lines.append(
                "| \(field.label) | \(format(match.precision)) | \(format(match.recall)) | \(format(match.f1)) | \(match.truePositive) | \(match.falsePositive) | \(match.falseNegative) |"
            )
        }

        let overall = metrics.overall
        lines.append(
            "| Overall | \(format(overall.precision)) | \(format(overall.recall)) | \(format(overall.f1)) | \(overall.truePositive) | \(overall.falsePositive) | \(overall.falseNegative) |"
        )

        lines.append("")
        lines.append("## Per-Case F1")
        lines.append("")
        lines.append("| Case ID | Profile | SKU | Qty | Unit Price | Extended Price | Line Type | Doc ID | Overall |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|")

        for caseMetrics in metrics.cases.sorted(by: { $0.caseId < $1.caseId }) {
            lines.append(
                "| \(caseMetrics.caseId) | \(caseMetrics.profile) | \(format(caseMetrics.fieldMatches[.sku]?.f1 ?? 0)) | \(format(caseMetrics.fieldMatches[.quantity]?.f1 ?? 0)) | \(format(caseMetrics.fieldMatches[.unitPrice]?.f1 ?? 0)) | \(format(caseMetrics.fieldMatches[.extendedPrice]?.f1 ?? 0)) | \(format(caseMetrics.fieldMatches[.lineType]?.f1 ?? 0)) | \(format(caseMetrics.fieldMatches[.documentIdentifier]?.f1 ?? 0)) | \(format(caseMetrics.overall.f1)) |"
            )
        }

        lines.append("")
        lines.append("## Notes")
        lines.append("")
        lines.append("- Ground truth source: PR-07 parser goldens under `Fixtures/ParserCorpus/expected/`.")
        lines.append("- Alignment strategy: deterministic key bucketing by normalized part number, then normalized description; position-based pairing within each bucket.")
        lines.append("- Normalization: trim + collapse whitespace + case-fold (diacritic-insensitive). Numeric comparisons use integer quantities/cents.")

        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let normalized = normalize(value) {
                return normalized
            }
        }
        return nil
    }

    private static func projectRootURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["PROJECT_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let evaluatorFileURL = URL(fileURLWithPath: #filePath, isDirectory: false)
        return evaluatorFileURL
            .deletingLastPathComponent() // POScannerAppTests
            .deletingLastPathComponent() // project root
    }

    private static func goldenRootDirectory() -> URL {
        projectRootURL()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("ParserCorpus", isDirectory: true)
            .appendingPathComponent("expected", isDirectory: true)
    }

    private static func defaultReportDirectory() -> URL {
        if let overridden = ProcessInfo.processInfo.environment["PARSER_METRICS_REPORT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return URL(fileURLWithPath: overridden, isDirectory: true)
        }

        if let ciReports = ProcessInfo.processInfo.environment["CI_REPORTS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ciReports.isEmpty {
            return URL(fileURLWithPath: ciReports, isDirectory: true)
        }

        return projectRootURL()
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("release-gate", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
    }
}
