//
//  POScannerAppTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
import ShopmikeyCoreNetworking
@testable import POScannerApp

struct SandboxInvariantTests {
    @Test func baseURLIsSandbox() async throws {
        #expect(ShopmonkeyAPI.baseURL.host == "sandbox-api.shopmonkey.cloud")
    }
}

struct PurchaseOrderStatusBucketTests {
    @Test func submittedAliasesMapToSubmittedBucket() {
        #expect(PurchaseOrderStatusBucket(rawStatus: "submitted") == .submitted)
        #expect(PurchaseOrderStatusBucket(rawStatus: "success") == .submitted)
        #expect(PurchaseOrderStatusBucket(rawStatus: "closed") == .submitted)
        #expect(PurchaseOrderStatusBucket(rawStatus: "fulfilled") == .submitted)
    }

    @Test func pendingAliasesMapToPendingBucket() {
        #expect(PurchaseOrderStatusBucket(rawStatus: "submitting") == .pending)
        #expect(PurchaseOrderStatusBucket(rawStatus: "draft") == .pending)
        #expect(PurchaseOrderStatusBucket(rawStatus: "ordered") == .pending)
        #expect(PurchaseOrderStatusBucket(rawStatus: "pending") == .pending)
    }

    @Test func failedAliasesMapToFailedBucket() {
        #expect(PurchaseOrderStatusBucket(rawStatus: "failed") == .failed)
        #expect(PurchaseOrderStatusBucket(rawStatus: "error") == .failed)
        #expect(PurchaseOrderStatusBucket(rawStatus: "cancelled") == .failed)
    }

    @Test func emptyOrUnknownStatusesAreIgnored() {
        #expect(PurchaseOrderStatusBucket(rawStatus: "") == .ignored)
        #expect(PurchaseOrderStatusBucket(rawStatus: "mystery-status") == .ignored)
    }
}
