//
//  AuthErrorMessageTests.swift
//  POScannerAppTests
//

import ShopmikeyCoreNetworking
import Testing
@testable import POScannerApp

struct AuthErrorMessageTests {
    @Test
    func missingTokenMapsToMissingAPIKeyMessage() {
        let message = authErrorMessage(for: APIError.missingToken, isAuthConfigured: false)
        #expect(message == "API key missing. Add it in Settings.")
    }

    @Test
    func unauthorizedMapsToInvalidKeyMessage() {
        let message401 = authErrorMessage(for: APIError.unauthorized, isAuthConfigured: true)
        #expect(message401 == "API key invalid or expired.")

        let message403 = authErrorMessage(for: APIError.serverError(403), isAuthConfigured: true)
        #expect(message403 == "API key invalid or expired.")
    }
}
