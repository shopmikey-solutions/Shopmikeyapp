//
//  LoadingStabilityTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreNetworking
import Testing
@testable import POScannerApp

struct LoadingStabilityTests {
    @Test func treatsCancellationErrorAsRequestCancellation() {
        #expect(isRequestCancellation(CancellationError()))
    }

    @Test func treatsURLErrorCancelledAsRequestCancellation() {
        #expect(isRequestCancellation(URLError(.cancelled)))
    }

    @Test func treatsWrappedCancelledNetworkAPIErrorAsRequestCancellation() {
        #expect(isRequestCancellation(APIError.network(URLError(.cancelled))))
    }

    @Test func doesNotTreatOfflineAsCancellation() {
        #expect(!isRequestCancellation(URLError(.notConnectedToInternet)))
        #expect(!isRequestCancellation(APIError.network(URLError(.notConnectedToInternet))))
    }
}
