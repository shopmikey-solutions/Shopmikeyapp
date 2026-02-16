//
//  POScannerAppTests.swift
//  POScannerAppTests
//

import Foundation
import Testing
@testable import POScannerApp

struct SandboxInvariantTests {
    @Test func baseURLIsSandbox() async throws {
        #expect(ShopmonkeyAPI.baseURL.host == "sandbox-api.shopmonkey.cloud")
    }
}
