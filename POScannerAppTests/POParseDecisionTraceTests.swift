//
//  POParseDecisionTraceTests.swift
//  POScannerAppTests
//

import Testing
import ShopmikeyCoreModels
import Foundation
@testable import POScannerApp

@Suite(.serialized)
struct POParseDecisionTraceTests {
    @Test func capturesProfileAndRejectedLinesWhenTraceEnabled() {
        let parser = POParser()
        parser.decisionTraceEnabled = true

        _ = parser.parse(from: """
        MY CART (11)
        2016 Subaru Outback
        Denso Iridium TT Spark Plug - 4704
        Part # 4704 Line DEN
        - 6 + REMOVE
        $77.94
        FREE Pick Up
        Available within 24-48 hours.
        """, ignoreTaxAndTotals: true)

        guard let trace = parser.latestDecisionTrace else {
            Issue.record("Expected decision trace")
            return
        }

        #expect(trace.chosenProfile == .ecommerceCart)
        #expect(trace.fallbackTriggered == true)
        #expect(trace.rejectedLines.contains(where: { $0.line.localizedCaseInsensitiveContains("FREE Pick Up") }))
    }
}
