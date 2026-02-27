import Foundation

enum ParserGoldenComparatorError: LocalizedError {
    case missingExpected(caseId: String, expectedPath: String)
    case unreadableExpected(caseId: String, expectedPath: String, underlying: Error)
    case invalidExpected(caseId: String, expectedPath: String, underlying: Error)
    case mismatch(caseId: String, expectedPath: String, details: String)

    var errorDescription: String? {
        switch self {
        case .missingExpected(let caseId, let expectedPath):
            return "Golden file missing for case: \(caseId) at \(expectedPath). Run: bash scripts/update_parser_goldens.sh to refresh."
        case .unreadableExpected(let caseId, let expectedPath, let underlying):
            return "Could not read golden for case: \(caseId) at \(expectedPath): \(underlying.localizedDescription)"
        case .invalidExpected(let caseId, let expectedPath, let underlying):
            return "Golden JSON is invalid for case: \(caseId) at \(expectedPath): \(underlying.localizedDescription)"
        case .mismatch(let caseId, let expectedPath, let details):
            return "Golden mismatch for case: \(caseId)\nExpected file: \(expectedPath)\nRun: bash scripts/update_parser_goldens.sh to refresh\n\n\(details)"
        }
    }
}

enum ParserGoldenComparator {
    private static let lineContext = 2
    private static let maxPathDiffs = 20

    static func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func diff(expected: Data, actual: Data) -> String {
        let pathDiffs = (try? pathDifferences(expected: expected, actual: actual, limit: maxPathDiffs)) ?? []
        let lineDiff = unifiedLineDiff(expected: expected, actual: actual)

        if pathDiffs.isEmpty {
            return "Unified diff (context ±\(lineContext) lines):\n\(lineDiff)"
        }

        let pathSummary = pathDiffs.map { "- \($0)" }.joined(separator: "\n")
        return "Path differences:\n\(pathSummary)\n\nUnified diff (context ±\(lineContext) lines):\n\(lineDiff)"
    }

    static func assertGolden<T: Encodable>(
        caseId: String,
        actualModel: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        _ = (file, line)

        let expectedURL = expectedGoldenURL(caseId: caseId)
        let actualData = try canonicalJSONData(actualModel)

        if shouldUpdateGoldens {
            try writeUpdatedGolden(actualData, to: expectedURL, caseId: caseId)
            return
        }

        guard FileManager.default.fileExists(atPath: expectedURL.path) else {
            throw ParserGoldenComparatorError.missingExpected(caseId: caseId, expectedPath: expectedURL.path)
        }

        let expectedRawData: Data
        do {
            expectedRawData = try Data(contentsOf: expectedURL)
        } catch {
            throw ParserGoldenComparatorError.unreadableExpected(
                caseId: caseId,
                expectedPath: expectedURL.path,
                underlying: error
            )
        }

        let expectedData: Data
        do {
            expectedData = try canonicalizeJSONData(expectedRawData)
        } catch {
            throw ParserGoldenComparatorError.invalidExpected(
                caseId: caseId,
                expectedPath: expectedURL.path,
                underlying: error
            )
        }

        guard expectedData != actualData else { return }

        throw ParserGoldenComparatorError.mismatch(
            caseId: caseId,
            expectedPath: expectedURL.path,
            details: diff(expected: expectedData, actual: actualData)
        )
    }

    private static var shouldUpdateGoldens: Bool {
#if UPDATE_PARSER_GOLDENS
        true
#else
        ProcessInfo.processInfo.environment["UPDATE_PARSER_GOLDENS"] == "1"
#endif
    }

    private static func writeUpdatedGolden(_ data: Data, to url: URL, caseId: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = try? Data(contentsOf: url)
        if existing == data {
            return
        }

        try data.write(to: url, options: .atomic)
        print("Updated parser golden: \(caseId) -> \(url.path)")
    }

    private static func expectedGoldenURL(caseId: String) -> URL {
        let root = projectRootURL()
        return root
            .appendingPathComponent("POScannerAppTests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("ParserCorpus", isDirectory: true)
            .appendingPathComponent("expected", isDirectory: true)
            .appendingPathComponent("\(caseId).json", isDirectory: false)
    }

    private static func projectRootURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["PROJECT_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let comparatorFileURL = URL(fileURLWithPath: #filePath, isDirectory: false)
        return comparatorFileURL
            .deletingLastPathComponent() // POScannerAppTests
            .deletingLastPathComponent() // project root
    }

    private static func canonicalizeJSONData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try canonicalizeJSONObjectData(object)
    }

    private static func canonicalizeJSONObjectData(_ object: Any) throws -> Data {
        switch object {
        case let dictionary as [String: Any]:
            let normalized = dictionary.mapValues { normalizeJSONValue($0) }
            return try JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys])
        case let array as [Any]:
            let normalized = array.map(normalizeJSONValue)
            return try JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys])
        case is NSNull, is String, is NSNumber:
            return try JSONSerialization.data(withJSONObject: ["_": normalizeJSONValue(object)], options: [.prettyPrinted, .sortedKeys])
        default:
            let fallback = String(describing: object)
            return try JSONSerialization.data(withJSONObject: ["_": fallback], options: [.prettyPrinted, .sortedKeys])
        }
    }

    private static func normalizeJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { normalizeJSONValue($0) }
        case let array as [Any]:
            return array.map(normalizeJSONValue)
        case is NSNull, is String, is NSNumber:
            return value
        default:
            return String(describing: value)
        }
    }

    private static func pathDifferences(expected: Data, actual: Data, limit: Int) throws -> [String] {
        let expectedObject = try JSONSerialization.jsonObject(with: expected, options: [.fragmentsAllowed])
        let actualObject = try JSONSerialization.jsonObject(with: actual, options: [.fragmentsAllowed])

        var differences: [String] = []
        collectDifferences(expected: expectedObject, actual: actualObject, path: "$", into: &differences, limit: limit)
        return differences
    }

    private static func collectDifferences(
        expected: Any,
        actual: Any,
        path: String,
        into differences: inout [String],
        limit: Int
    ) {
        guard differences.count < limit else { return }

        if let expectedDict = expected as? [String: Any], let actualDict = actual as? [String: Any] {
            let keys = Set(expectedDict.keys).union(actualDict.keys).sorted()
            for key in keys where differences.count < limit {
                let childPath = "\(path).\(key)"
                switch (expectedDict[key], actualDict[key]) {
                case (.none, .some(let actualValue)):
                    differences.append("\(childPath) unexpected value in actual: \(renderJSONValue(actualValue))")
                case (.some(let expectedValue), .none):
                    differences.append("\(childPath) missing in actual, expected: \(renderJSONValue(expectedValue))")
                case (.some(let expectedValue), .some(let actualValue)):
                    collectDifferences(
                        expected: expectedValue,
                        actual: actualValue,
                        path: childPath,
                        into: &differences,
                        limit: limit
                    )
                case (.none, .none):
                    continue
                }
            }
            return
        }

        if let expectedArray = expected as? [Any], let actualArray = actual as? [Any] {
            if expectedArray.count != actualArray.count {
                differences.append("\(path) count mismatch expected=\(expectedArray.count) actual=\(actualArray.count)")
            }
            let count = min(expectedArray.count, actualArray.count)
            if count == 0 { return }
            for index in 0..<count where differences.count < limit {
                collectDifferences(
                    expected: expectedArray[index],
                    actual: actualArray[index],
                    path: "\(path)[\(index)]",
                    into: &differences,
                    limit: limit
                )
            }
            return
        }

        let expectedText = renderJSONValue(expected)
        let actualText = renderJSONValue(actual)
        if expectedText != actualText {
            differences.append("\(path) expected=\(expectedText) actual=\(actualText)")
        }
    }

    private static func renderJSONValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return "\"\(string)\""
        case is NSNull:
            return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted().joined(separator: ",")
            return "{\(keys)}"
        case let array as [Any]:
            return "[count=\(array.count)]"
        default:
            return String(describing: value)
        }
    }

    private static func unifiedLineDiff(expected: Data, actual: Data) -> String {
        let expectedText = String(decoding: expected, as: UTF8.self)
        let actualText = String(decoding: actual, as: UTF8.self)
        let expectedLines = expectedText.components(separatedBy: "\n")
        let actualLines = actualText.components(separatedBy: "\n")

        let maxCount = max(expectedLines.count, actualLines.count)
        var mismatchIndex = 0
        while mismatchIndex < maxCount {
            let expectedLine = mismatchIndex < expectedLines.count ? expectedLines[mismatchIndex] : nil
            let actualLine = mismatchIndex < actualLines.count ? actualLines[mismatchIndex] : nil
            if expectedLine != actualLine {
                break
            }
            mismatchIndex += 1
        }

        if mismatchIndex >= maxCount {
            return "No differences found."
        }

        let start = max(0, mismatchIndex - lineContext)
        let end = min(maxCount - 1, mismatchIndex + lineContext)
        var rows: [String] = []

        for index in start...end {
            let lineNumber = index + 1
            let expectedLine = index < expectedLines.count ? expectedLines[index] : "<missing>"
            let actualLine = index < actualLines.count ? actualLines[index] : "<missing>"
            rows.append(String(format: "E%04d | %@", lineNumber, expectedLine))
            rows.append(String(format: "A%04d | %@", lineNumber, actualLine))
        }

        return rows.joined(separator: "\n")
    }
}
