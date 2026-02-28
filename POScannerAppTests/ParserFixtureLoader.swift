import Foundation
import ShopmikeyCoreModels

enum ParserFixtureProfile: String, Codable {
    case ecommerceCart
    case tabularInvoice
    case generic
}

struct ParserFixtureRow: Codable {
    let cells: [String]
    let confidence: Double?
}

struct ParserFixtureCase: Codable {
    let schemaVersion: Int
    let caseId: String
    let profile: ParserFixtureProfile
    let vendorHint: String?
    let rawText: String
    let rows: [ParserFixtureRow]
    let barcodes: [String]
    let locale: String
    let currency: String
    let sourceURL: URL
}

enum ParserFixtureLoaderError: LocalizedError {
    case corpusMissing(searchedPaths: [String])
    case unreadableFixture(file: String, underlying: Error)
    case invalidJSON(file: String, underlying: Error)
    case unsupportedSchemaVersion(file: String, found: Int)
    case missingRawText(file: String)
    case missingCaseId(file: String)

    var errorDescription: String? {
        switch self {
        case .corpusMissing(let searchedPaths):
            return "Parser corpus folder not found. Searched: \(searchedPaths.joined(separator: ", "))"
        case .unreadableFixture(let file, let underlying):
            return "Unable to read fixture at \(file): \(underlying.localizedDescription)"
        case .invalidJSON(let file, let underlying):
            return "Invalid fixture JSON at \(file): \(underlying.localizedDescription)"
        case .unsupportedSchemaVersion(let file, let found):
            return "Unsupported schemaVersion=\(found) in \(file). Expected schemaVersion=1."
        case .missingRawText(let file):
            return "Fixture rawText is missing or empty: \(file)"
        case .missingCaseId(let file):
            return "Fixture caseId is missing or empty: \(file)"
        }
    }
}

enum ParserFixtureLoader {
    private static let schemaVersion = 1

    private struct RawFixture: Decodable {
        let schemaVersion: Int
        let caseId: String
        let profile: ParserFixtureProfile
        let vendorHint: String?
        let rawText: String
        let rows: [ParserFixtureRow]?
        let barcodes: [String]?
        let locale: String?
        let currency: String?
    }

    private final class BundleAnchor {}

    static func loadAll() throws -> [ParserFixtureCase] {
        let corpusRoot = try resolveCorpusRoot()
        let casesRoot = corpusRoot.appendingPathComponent("cases", isDirectory: true)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: casesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ParserFixtureLoaderError.corpusMissing(searchedPaths: [casesRoot.path])
        }

        var fixtures: [ParserFixtureCase] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "input.json" else { continue }
            let fixture = try loadFixture(from: fileURL)
            fixtures.append(fixture)
        }

        return fixtures.sorted { lhs, rhs in
            lhs.caseId.localizedStandardCompare(rhs.caseId) == .orderedAscending
        }
    }

    private static func resolveCorpusRoot() throws -> URL {
        let bundle = Bundle(for: BundleAnchor.self)
        var searchedPaths: [String] = []

        if let resourceURL = bundle.resourceURL {
            let directRoot = resourceURL.appendingPathComponent("ParserCorpus", isDirectory: true)
            searchedPaths.append(directRoot.path)
            if FileManager.default.fileExists(atPath: directRoot.path) {
                return directRoot
            }

            let direct = resourceURL.appendingPathComponent("Fixtures/ParserCorpus", isDirectory: true)
            searchedPaths.append(direct.path)
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }

            if let nestedRoot = bundle.url(forResource: "ParserCorpus", withExtension: nil) {
                searchedPaths.append(nestedRoot.path)
                if FileManager.default.fileExists(atPath: nestedRoot.path) {
                    return nestedRoot
                }
            }

            if let nested = bundle.url(
                forResource: "ParserCorpus",
                withExtension: nil,
                subdirectory: "Fixtures"
            ) {
                searchedPaths.append(nested.path)
                if FileManager.default.fileExists(atPath: nested.path) {
                    return nested
                }
            }

            if let discovered = discoverCorpusRoot(in: resourceURL) {
                return discovered
            }
        }

        throw ParserFixtureLoaderError.corpusMissing(searchedPaths: searchedPaths)
    }

    private static func discoverCorpusRoot(in resourceURL: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == "ParserCorpus" {
            let casesURL = url.appendingPathComponent("cases", isDirectory: true)
            if FileManager.default.fileExists(atPath: casesURL.path) {
                return url
            }
        }

        return nil
    }

    private static func loadFixture(from fileURL: URL) throws -> ParserFixtureCase {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ParserFixtureLoaderError.unreadableFixture(file: fileURL.path, underlying: error)
        }

        let rawFixture: RawFixture
        do {
            rawFixture = try JSONDecoder().decode(RawFixture.self, from: data)
        } catch {
            throw ParserFixtureLoaderError.invalidJSON(file: fileURL.path, underlying: error)
        }

        guard rawFixture.schemaVersion == schemaVersion else {
            throw ParserFixtureLoaderError.unsupportedSchemaVersion(
                file: fileURL.path,
                found: rawFixture.schemaVersion
            )
        }

        let caseId = rawFixture.caseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caseId.isEmpty else {
            throw ParserFixtureLoaderError.missingCaseId(file: fileURL.path)
        }

        let rawText = rawFixture.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            throw ParserFixtureLoaderError.missingRawText(file: fileURL.path)
        }

        let locale = rawFixture.locale?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = rawFixture.currency?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedLocale: String
        if let locale, !locale.isEmpty {
            resolvedLocale = locale
        } else {
            resolvedLocale = "en_US"
        }

        let resolvedCurrency: String
        if let currency, !currency.isEmpty {
            resolvedCurrency = currency
        } else {
            resolvedCurrency = "USD"
        }

        return ParserFixtureCase(
            schemaVersion: rawFixture.schemaVersion,
            caseId: caseId,
            profile: rawFixture.profile,
            vendorHint: rawFixture.vendorHint,
            rawText: rawFixture.rawText,
            rows: rawFixture.rows ?? [],
            barcodes: rawFixture.barcodes ?? [],
            locale: resolvedLocale,
            currency: resolvedCurrency,
            sourceURL: fileURL
        )
    }
}
