//
//  DiagnosticsSupportBundleTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

struct DiagnosticsSupportBundleTests {
    @Test
    func testBundleEncodingIncludesExpectedTopLevelKeys() throws {
        let bundle = DiagnosticsSupportBundle(
            schemaVersion: 1,
            generatedAt: "2026-03-02T18:30:00Z",
            app: .init(bundleId: "com.shopmikey.app", version: "1.2.3", build: "456"),
            syncHealthSummary: .init(pendingQueued: 1, retrying: 2, inProgress: 3, failed: 4),
            operations: [
                .init(
                    idShort: "12345678",
                    type: "addTicketLineItem",
                    status: "pending",
                    retryCount: 0,
                    createdAt: "2026-03-02T18:00:00Z",
                    lastAttemptAt: nil,
                    nextAttemptAt: nil,
                    lastErrorCode: nil
                )
            ]
        )

        let data = try encode(bundle: bundle)
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("\"schemaVersion\""))
        #expect(text.contains("\"generatedAt\""))
        #expect(text.contains("\"app\""))
        #expect(text.contains("\"operations\""))
    }

    @Test
    func testOperationIdIsTruncated() {
        let operation = makeOperation(
            id: UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!,
            payloadFingerprint: "safe-fingerprint"
        )

        let summary = DiagnosticsSupportBundle.OperationSummary.from(operation: operation)
        #expect(summary.idShort == "12345678")
    }

    @Test
    func testNoSensitiveKeysArePresent() throws {
        let operation = makeOperation(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            payloadFingerprint: "Authorization: Bearer token __smk_receive_key__ barcode=12345 ticket_id=abcd"
        )

        let builder = DiagnosticsSupportBundleBuilder(
            now: { Date(timeIntervalSince1970: 1_772_900_000) },
            bundleInfo: .main,
            outputDirectory: FileManager.default.temporaryDirectory
        )

        let bundle = builder.makeBundle(from: [operation])
        let data = try encode(bundle: bundle)
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains("Authorization"))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("barcode"))
        #expect(!text.contains("payload"))
        #expect(!text.contains("__smk_receive_key__"))
    }

    private func encode(bundle: DiagnosticsSupportBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    private func makeOperation(id: UUID, payloadFingerprint: String) -> SyncOperation {
        SyncOperation(
            id: id,
            type: .addTicketLineItem,
            payloadFingerprint: payloadFingerprint,
            status: .pending,
            retryCount: 1,
            createdAt: Date(timeIntervalSince1970: 1_772_899_900),
            lastAttemptAt: Date(timeIntervalSince1970: 1_772_899_950),
            nextAttemptAt: Date(timeIntervalSince1970: 1_772_900_100),
            lastErrorCode: "SMK-NET-TIMEOUT"
        )
    }
}
