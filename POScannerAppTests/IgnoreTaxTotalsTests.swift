//
//  IgnoreTaxTotalsTests.swift
//  POScannerAppTests
//

import Testing
import ShopmikeyCoreModels
@testable import POScannerApp

struct IgnoreTaxTotalsTests {
    @Test func taxSubtotalTotalLinesNeverBecomeItemsWhenIgnoreIsOn() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Subtotal USD 1,573.20
        HST@13% 204.52
        TOTAL DUE 1,777.72
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.isEmpty)
    }

    @Test func taxSubtotalTotalLinesStillDoNotBecomeItemsWhenIgnoreIsOff() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Subtotal USD 1,573.20
        HST@13% 204.52
        TOTAL DUE 1,777.72
        """, ignoreTaxAndTotals: false)

        #expect(parsed.items.isEmpty)
    }

    @Test func productLinesContainingTotalAreNotFiltered() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: "Total Seal Kit XG7317 3 EA 29.97", ignoreTaxAndTotals: true)

        #expect(parsed.items.count == 1)
        guard let item = parsed.items.first else { return }
        #expect(item.quantity == 3)
        #expect(item.costCents == 2997)
        #expect(item.partNumber == "XG7317")
    }
}

