//
//  DiagnosticsCodeTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import Testing
import ShopmikeyCoreNetworking
@testable import POScannerApp

struct DiagnosticsCodeTests {
    @Test func diagnosticCodesAreUnique() {
        let rawCodes = DiagnosticCode.allCases.map(\.rawValue)
        #expect(Set(rawCodes).count == rawCodes.count)
    }

    @Test func diagnosticCodesMatchExpectedPattern() throws {
        let regex = try NSRegularExpression(pattern: #"^SMK-[A-Z]+-[A-Z0-9]+-[A-Z0-9_]+$"#)
        for code in DiagnosticCode.allCases {
            let range = NSRange(location: 0, length: code.rawValue.utf16.count)
            let match = regex.firstMatch(in: code.rawValue, options: [], range: range)
            #expect(match != nil)
        }
    }

    @Test func diagnosticMetadataIsNonEmpty() {
        for code in DiagnosticCode.allCases {
            #expect(!code.userFacingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!code.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!code.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!code.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func apiErrorDiagnosticMappingIsStable() {
        #expect(APIError.unauthorized.diagnosticCode == .authUnauthorized401)
        #expect(APIError.serverError(403).diagnosticCode == .authForbidden403)
        #expect(APIError.serverError(404).diagnosticCode == .apiNotFound404)
        #expect(APIError.serverError(409).diagnosticCode == .apiConflict409)
        #expect(APIError.serverError(422).diagnosticCode == .apiValidate422)
        #expect(APIError.rateLimited.diagnosticCode == .netRate429)
        #expect(APIError.serverError(500).diagnosticCode == .apiServer5xx)
        #expect(APIError.decodingFailed.diagnosticCode == .apiDecodeBadJSON)
        #expect(APIError.network(URLError(.timedOut)).diagnosticCode == .netTimeoutRequest)
        #expect(APIError.network(URLError(.notConnectedToInternet)).diagnosticCode == .netConnectivityUnreachable)
        #expect(APIError.serverError(499).diagnosticCode == .apiUnknownError)
    }

    @Test func fallbackDiagnosticCodeIsStableForUnknownErrors() {
        struct UnknownTestError: Error {}
        #expect(DiagnosticCode.from(error: UnknownTestError()) == .submitUnknownError)
    }
}
