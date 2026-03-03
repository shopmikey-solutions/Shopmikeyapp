//
//  DiagnosticsSupportBundle.swift
//  POScannerApp
//

import Foundation
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

    let schemaVersion: Int
    let generatedAt: String
    let app: AppInfo
    let syncHealthSummary: SyncHealthSummary
    let operations: [OperationSummary]
}

struct DiagnosticsSupportBundleBuildResult: Sendable {
    let bundle: DiagnosticsSupportBundle
    let fileURL: URL
}

struct DiagnosticsSupportBundleBuilder {
    private let now: @Sendable () -> Date
    private let bundleInfo: Bundle
    private let outputDirectory: URL

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        bundleInfo: Bundle = .main,
        outputDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.now = now
        self.bundleInfo = bundleInfo
        self.outputDirectory = outputDirectory
    }

    func buildAndWrite(from operations: [SyncOperation]) throws -> DiagnosticsSupportBundleBuildResult {
        let generatedDate = now()
        let bundle = makeBundle(from: operations, generatedDate: generatedDate)
        let url = try write(bundle: bundle, generatedDate: generatedDate)
        return DiagnosticsSupportBundleBuildResult(bundle: bundle, fileURL: url)
    }

    func makeBundle(from operations: [SyncOperation]) -> DiagnosticsSupportBundle {
        makeBundle(from: operations, generatedDate: now())
    }

    private func makeBundle(from operations: [SyncOperation], generatedDate: Date) -> DiagnosticsSupportBundle {
        let sortedOperations = operations.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
        let operationSummaries = sortedOperations.map(DiagnosticsSupportBundle.OperationSummary.from)
        return DiagnosticsSupportBundle(
            schemaVersion: 1,
            generatedAt: Self.iso8601String(from: generatedDate),
            app: makeAppInfo(),
            syncHealthSummary: summarize(operations: sortedOperations),
            operations: operationSummaries
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
