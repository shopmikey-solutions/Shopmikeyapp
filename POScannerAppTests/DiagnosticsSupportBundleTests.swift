//
//  DiagnosticsSupportBundleTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreNetworking
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
            shopmonkeyBaseURL: "https://sandbox-api.shopmonkey.cloud/v3",
            authConfigured: true,
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
            ],
            lastNetworkFailures: [
                .init(
                    endpointPath: "/v3/order/:id/service",
                    statusCode: 401,
                    urlErrorCode: nil,
                    timestamp: "2026-03-02T18:20:00Z"
                )
            ]
        )

        let data = try encode(bundle: bundle)
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("\"schemaVersion\""))
        #expect(text.contains("\"generatedAt\""))
        #expect(text.contains("\"app\""))
        #expect(text.contains("\"operations\""))
        #expect(text.contains("\"shopmonkeyBaseURL\""))
        #expect(text.contains("\"authConfigured\""))
        #expect(text.contains("\"lastNetworkFailures\""))
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

        let failureEntry = NetworkDiagnosticsEntry(
            method: "GET",
            url: "https://sandbox-api.shopmonkey.cloud/v3/order/ORDER123/service",
            statusCode: 403,
            requestBodyPreview: "{\"barcode\":\"12345\"}",
            responseBodyPreview: nil,
            errorSummary: "The operation couldn’t be completed. (NSURLErrorDomain error -1009.)"
        )
        let bundle = builder.makeBundle(
            from: [operation],
            shopmonkeyBaseURL: ShopmonkeyBaseURL.sandboxV3,
            authConfigured: true,
            networkFailures: [failureEntry]
        )
        let data = try encode(bundle: bundle)
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains("Authorization"))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("barcode"))
        #expect(!text.contains("payload"))
        #expect(!text.contains("__smk_receive_key__"))
        #expect(!text.contains("ORDER123"))

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let failures = try #require(json["lastNetworkFailures"] as? [[String: Any]])
        let firstFailure = try #require(failures.first)
        let endpointPath = try #require(firstFailure["endpointPath"] as? String)
        #expect(endpointPath == "/v3/order/:id/service")
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
