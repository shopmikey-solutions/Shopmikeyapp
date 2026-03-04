//
//  DiagnosticsSupportBundle.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync

struct DiagnosticsSupportBundle: Codable, Sendable {
    struct AppInfo: Codable, Sendable {
        let bundleId: String
        let version: String
        let build: String
    }

    struct SyncHealthSummary: Codable, Sendable {
        let pendingQueued: Int
        let retrying: Int
        let inProgress: Int
        let failed: Int
    }

    struct OperationSummary: Codable, Sendable {
        let idShort: String
        let type: String
        let status: String
        let retryCount: Int
        let createdAt: String
        let lastAttemptAt: String?
        let nextAttemptAt: String?
        let lastErrorCode: String?

        static func from(operation: SyncOperation) -> OperationSummary {
            OperationSummary(
                idShort: String(operation.id.uuidString.prefix(8)),
                type: operation.type.rawValue,
                status: operation.status.rawValue,
                retryCount: operation.retryCount,
                createdAt: DiagnosticsSupportBundleBuilder.iso8601String(from: operation.createdAt),
                lastAttemptAt: operation.lastAttemptAt.map {
                    DiagnosticsSupportBundleBuilder.iso8601String(from: $0)
                },
                nextAttemptAt: operation.nextAttemptAt.map {
                    DiagnosticsSupportBundleBuilder.iso8601String(from: $0)
                },
                lastErrorCode: operation.lastErrorCode?.nonEmptyTrimmed
            )
        }
    }

    struct NetworkFailureSummary: Codable, Sendable {
        let endpointPath: String
        let statusCode: Int?
        let urlErrorCode: Int?
        let timestamp: String
    }

    let schemaVersion: Int
    let generatedAt: String
    let app: AppInfo
    let shopmonkeyBaseURL: String
    let authConfigured: Bool
    let syncHealthSummary: SyncHealthSummary
    let operations: [OperationSummary]
    let lastNetworkFailures: [NetworkFailureSummary]
}

struct DiagnosticsSupportBundleBuildResult: Sendable {
    let bundle: DiagnosticsSupportBundle
    let fileURL: URL
}

struct DiagnosticsSupportBundleBuilder {
    private let now: @Sendable () -> Date
    private let bundleInfo: Bundle
    private let outputDirectory: URL
    private let maxFailureEntries: Int
    private static let endpointPathAllowlist: Set<String> = [
        "v3",
        "order",
        "service",
        "part",
        "fee",
        "tire",
        "vendor",
        "purchase_order",
        "line_item",
        "receive",
        "inventory_part",
        "search"
    ]

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        bundleInfo: Bundle = .main,
        outputDirectory: URL = FileManager.default.temporaryDirectory,
        maxFailureEntries: Int = 20
    ) {
        self.now = now
        self.bundleInfo = bundleInfo
        self.outputDirectory = outputDirectory
        self.maxFailureEntries = maxFailureEntries
    }

    func buildAndWrite(
        from operations: [SyncOperation],
        shopmonkeyBaseURL: URL,
        authConfigured: Bool,
        networkFailures: [NetworkDiagnosticsEntry]
    ) throws -> DiagnosticsSupportBundleBuildResult {
        let generatedDate = now()
        let bundle = makeBundle(
            from: operations,
            generatedDate: generatedDate,
            shopmonkeyBaseURL: shopmonkeyBaseURL,
            authConfigured: authConfigured,
            networkFailures: networkFailures
        )
        let url = try write(bundle: bundle, generatedDate: generatedDate)
        return DiagnosticsSupportBundleBuildResult(bundle: bundle, fileURL: url)
    }

    func makeBundle(
        from operations: [SyncOperation],
        shopmonkeyBaseURL: URL = ShopmonkeyBaseURL.sandboxV3,
        authConfigured: Bool = false,
        networkFailures: [NetworkDiagnosticsEntry] = []
    ) -> DiagnosticsSupportBundle {
        makeBundle(
            from: operations,
            generatedDate: now(),
            shopmonkeyBaseURL: shopmonkeyBaseURL,
            authConfigured: authConfigured,
            networkFailures: networkFailures
        )
    }

    private func makeBundle(
        from operations: [SyncOperation],
        generatedDate: Date,
        shopmonkeyBaseURL: URL,
        authConfigured: Bool,
        networkFailures: [NetworkDiagnosticsEntry]
    ) -> DiagnosticsSupportBundle {
        let sortedOperations = operations.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        let operationSummaries = sortedOperations.map(DiagnosticsSupportBundle.OperationSummary.from)
        let failureSummaries = summarizeNetworkFailures(networkFailures)
        return DiagnosticsSupportBundle(
            schemaVersion: 1,
            generatedAt: Self.iso8601String(from: generatedDate),
            app: makeAppInfo(),
            shopmonkeyBaseURL: shopmonkeyBaseURL.absoluteString,
            authConfigured: authConfigured,
            syncHealthSummary: summarize(operations: sortedOperations),
            operations: operationSummaries,
            lastNetworkFailures: failureSummaries
        )
    }

    private func makeAppInfo() -> DiagnosticsSupportBundle.AppInfo {
        let infoDictionary = bundleInfo.infoDictionary ?? [:]
        let version = (infoDictionary["CFBundleShortVersionString"] as? String)?.nonEmptyTrimmed ?? "unknown"
        let build = (infoDictionary["CFBundleVersion"] as? String)?.nonEmptyTrimmed ?? "unknown"
        return DiagnosticsSupportBundle.AppInfo(
            bundleId: bundleInfo.bundleIdentifier ?? "unknown",
            version: version,
            build: build
        )
    }

    private func summarize(operations: [SyncOperation]) -> DiagnosticsSupportBundle.SyncHealthSummary {
        var pendingQueued = 0
        var retrying = 0
        var inProgress = 0
        var failed = 0

        for operation in operations {
            switch operation.status {
            case .pending:
                if operation.retryCount > 0 || operation.nextAttemptAt != nil {
                    retrying += 1
                } else {
                    pendingQueued += 1
                }
            case .inProgress:
                inProgress += 1
            case .failed:
                failed += 1
            case .succeeded:
                continue
            }
        }

        return DiagnosticsSupportBundle.SyncHealthSummary(
            pendingQueued: pendingQueued,
            retrying: retrying,
            inProgress: inProgress,
            failed: failed
        )
    }

    private func summarizeNetworkFailures(_ entries: [NetworkDiagnosticsEntry]) -> [DiagnosticsSupportBundle.NetworkFailureSummary] {
        entries
            .filter(\.isFailure)
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(maxFailureEntries)
            .map { entry in
                DiagnosticsSupportBundle.NetworkFailureSummary(
                    endpointPath: sanitizedEndpointPath(from: entry.url),
                    statusCode: entry.statusCode,
                    urlErrorCode: networkErrorCode(from: entry.errorSummary),
                    timestamp: Self.iso8601String(from: entry.timestamp)
                )
            }
    }

    private func sanitizedEndpointPath(from rawURLString: String) -> String {
        guard let components = URLComponents(string: rawURLString) else {
            return "/"
        }

        let path = components.path
        guard !path.isEmpty else { return "/" }

        let segments = path.split(separator: "/")
        if segments.isEmpty { return "/" }

        let sanitized = segments.map { segment -> String in
            let token = String(segment).lowercased()
            if Self.endpointPathAllowlist.contains(token) {
                return token
            }
            return ":id"
        }

        return "/" + sanitized.joined(separator: "/")
    }

    private func networkErrorCode(from errorSummary: String?) -> Int? {
        guard let errorSummary, !errorSummary.isEmpty else { return nil }
        let pattern = #"NSURLErrorDomain error (-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(errorSummary.startIndex..<errorSummary.endIndex, in: errorSummary)
        guard let match = regex.firstMatch(in: errorSummary, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: errorSummary) else {
            return nil
        }
        return Int(errorSummary[valueRange])
    }

    private func write(bundle: DiagnosticsSupportBundle, generatedDate: Date) throws -> URL {
        let fileName = "shopmikey_diagnostics_\(Self.fileNameTimestamp(from: generatedDate)).json"
        let fileURL = outputDirectory.appendingPathComponent(fileName)
        let data = try Self.makeEncoder().encode(bundle)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func fileNameTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
