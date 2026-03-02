//
//  SubmissionHealthViewModelTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreSync
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct SubmissionHealthViewModelTests {
    @Test @MainActor
    func testGroupsPendingRetryingFailedCorrectly() async {
        let baseDate = Date(timeIntervalSince1970: 1_772_900_000)
        let operations = [
            makeOperation(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                type: .syncInventory,
                status: .pending,
                retryCount: 0,
                createdAt: baseDate
            ),
            makeOperation(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                type: .submitPurchaseOrder,
                status: .pending,
                retryCount: 2,
                createdAt: baseDate.addingTimeInterval(10),
                nextAttemptAt: baseDate.addingTimeInterval(120)
            ),
            makeOperation(
                id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                type: .addTicketLineItem,
                status: .inProgress,
                retryCount: 0,
                createdAt: baseDate.addingTimeInterval(20)
            ),
            makeOperation(
                id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                type: .receivePurchaseOrderLineItem,
                status: .failed,
                retryCount: 3,
                createdAt: baseDate.addingTimeInterval(30),
                lastAttemptAt: baseDate.addingTimeInterval(40),
                lastErrorCode: "SMK-NET-RATE-429"
            ),
            makeOperation(
                id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
                type: .syncVendor,
                status: .succeeded,
                retryCount: 0,
                createdAt: baseDate.addingTimeInterval(50)
            )
        ]

        let viewModel = SubmissionHealthViewModel(fetchOperations: { operations })
        await viewModel.refresh()

        #expect(viewModel.pendingRows.count == 1)
        #expect(viewModel.retryingRows.count == 1)
        #expect(viewModel.inProgressRows.count == 1)
        #expect(viewModel.failedRows.count == 1)

        #expect(viewModel.pendingRows.first?.id.uuidString == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(viewModel.retryingRows.first?.id.uuidString == "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        #expect(viewModel.inProgressRows.first?.id.uuidString == "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
        #expect(viewModel.failedRows.first?.id.uuidString == "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    }

    @Test @MainActor
    func testSortingRulesAreDeterministic() async {
        let baseDate = Date(timeIntervalSince1970: 1_772_910_000)
        let operations = [
            makeOperation(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
                type: .syncInventory,
                status: .pending,
                retryCount: 0,
                createdAt: baseDate.addingTimeInterval(20)
            ),
            makeOperation(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                type: .syncInventory,
                status: .pending,
                retryCount: 0,
                createdAt: baseDate.addingTimeInterval(10)
            ),
            makeOperation(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!,
                type: .submitPurchaseOrder,
                status: .pending,
                retryCount: 1,
                createdAt: baseDate.addingTimeInterval(30),
                nextAttemptAt: baseDate.addingTimeInterval(180)
            ),
            makeOperation(
                id: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!,
                type: .submitPurchaseOrder,
                status: .pending,
                retryCount: 1,
                createdAt: baseDate.addingTimeInterval(40),
                nextAttemptAt: baseDate.addingTimeInterval(120)
            ),
            makeOperation(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000000")!,
                type: .receivePurchaseOrderLineItem,
                status: .pending,
                retryCount: 2,
                createdAt: baseDate.addingTimeInterval(50),
                nextAttemptAt: nil
            ),
            makeOperation(
                id: UUID(uuidString: "50000000-0000-0000-0000-000000000000")!,
                type: .addTicketLineItem,
                status: .failed,
                retryCount: 1,
                createdAt: baseDate.addingTimeInterval(60),
                lastAttemptAt: baseDate.addingTimeInterval(90)
            ),
            makeOperation(
                id: UUID(uuidString: "60000000-0000-0000-0000-000000000000")!,
                type: .addTicketLineItem,
                status: .failed,
                retryCount: 1,
                createdAt: baseDate.addingTimeInterval(70),
                lastAttemptAt: baseDate.addingTimeInterval(80)
            )
        ]

        let viewModel = SubmissionHealthViewModel(fetchOperations: { operations })
        await viewModel.refresh()

        #expect(viewModel.pendingRows.map(\.id.uuidString) == [
            "00000000-0000-0000-0000-000000000000",
            "10000000-0000-0000-0000-000000000000"
        ])
        #expect(viewModel.retryingRows.map(\.id.uuidString) == [
            "30000000-0000-0000-0000-000000000000",
            "20000000-0000-0000-0000-000000000000",
            "40000000-0000-0000-0000-000000000000"
        ])
        #expect(viewModel.failedRows.map(\.id.uuidString) == [
            "50000000-0000-0000-0000-000000000000",
            "60000000-0000-0000-0000-000000000000"
        ])
    }

    @Test @MainActor
    func testDoesNotExposeSensitiveFieldsInRowStrings() async {
        let sensitivePayload = "SENSITIVE_BARCODE_9999|customer_jane_doe|ticket_1234"
        let operation = makeOperation(
            id: UUID(uuidString: "ABCDEFAB-CDEF-CDEF-CDEF-ABCDEFABCDEF")!,
            type: .addTicketLineItem,
            status: .pending,
            retryCount: 1,
            createdAt: Date(timeIntervalSince1970: 1_772_920_000),
            nextAttemptAt: Date(timeIntervalSince1970: 1_772_920_120),
            lastErrorCode: "SMK-NET-TIMEOUT"
        ).withPayloadFingerprint(sensitivePayload)

        let viewModel = SubmissionHealthViewModel(fetchOperations: { [operation] })
        await viewModel.refresh()

        let blobs = (
            viewModel.pendingRows
            + viewModel.retryingRows
            + viewModel.inProgressRows
            + viewModel.failedRows
        ).map(\.visibleTextBlob)
            .joined(separator: "\n")

        #expect(!blobs.contains("SENSITIVE_BARCODE_9999"))
        #expect(!blobs.contains("customer_jane_doe"))
        #expect(!blobs.contains("ticket_1234"))
    }

    private func makeOperation(
        id: UUID,
        type: OperationType,
        status: OperationStatus,
        retryCount: Int,
        createdAt: Date,
        lastAttemptAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        lastErrorCode: String? = nil
    ) -> SyncOperation {
        SyncOperation(
            id: id,
            type: type,
            payloadFingerprint: "fingerprint-\(id.uuidString)",
            status: status,
            retryCount: retryCount,
            createdAt: createdAt,
            lastAttemptAt: lastAttemptAt,
            nextAttemptAt: nextAttemptAt,
            lastErrorCode: lastErrorCode
        )
    }
}

private extension SyncOperation {
    func withPayloadFingerprint(_ value: String) -> SyncOperation {
        SyncOperation(
            id: id,
            type: type,
            payloadFingerprint: value,
            status: status,
            retryCount: retryCount,
            createdAt: createdAt,
            lastAttemptAt: lastAttemptAt,
            nextAttemptAt: nextAttemptAt,
            lastErrorCode: lastErrorCode
        )
    }
}
