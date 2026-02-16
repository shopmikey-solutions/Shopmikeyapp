//
//  POParserAdvancedTests.swift
//  POScannerAppTests
//

import Testing
@testable import POScannerApp

struct POParserAdvancedTests {
    @Test func parsesMultiLineItemWithPNQtyAndCost() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ACME AUTO PARTS
        Brake Pad Set PN:BP-123
        Qty: 2
        $129.99
        """)

        #expect(parsed.vendorName == "ACME AUTO PARTS")
        #expect(!parsed.items.isEmpty)

        let item = parsed.items[0]
        #expect(item.quantity == 2)
        #expect(item.costCents == 12999)
        #expect(item.partNumber == "BP-123")
        #expect(item.confidence >= 0.8)
    }

    @Test func parsesInlineEAQtyPartAndCost() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: "Oil Filter XG7317 3 EA 29.97")

        #expect(parsed.vendorName == nil)
        #expect(!parsed.items.isEmpty)

        let item = parsed.items[0]
        #expect(item.quantity == 3)
        #expect(item.costCents == 2997)
        #expect(item.partNumber == "XG7317")
        #expect(item.confidence >= 0.6)
    }

    @Test func weakInputProducesLowConfidenceDefaults() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: "Widget")

        #expect(parsed.vendorName == nil)
        #expect(parsed.items.isEmpty)
    }

    @Test func classifiesMixedPartTireAndFeeRows() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Metro Auto Parts Supply
        Invoice INV-8831
        Front Brake Pad Set BP-123 Qty: 2 $89.99
        Michelin All Season Tire 225/45R17 Qty: 4 $110.00
        Shipping Freight $45.00
        Tax $12.00
        """)

        #expect(parsed.items.count >= 3)
        let parts = parsed.items.filter { $0.kind == .part }
        let tires = parsed.items.filter { $0.kind == .tire }
        let fees = parsed.items.filter { $0.kind == .fee }

        #expect(!parts.isEmpty)
        #expect(!tires.isEmpty)
        #expect(!fees.isEmpty)
        #expect(tires.first?.kindConfidence ?? 0 >= 0.75)
    }

    @Test func classifiesMountAndBalanceServiceAsFee() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Metro Auto Parts Supply
        Mount and Balance Service Qty: 4 $120.00
        """)

        #expect(parsed.items.count == 1)
        guard let item = parsed.items.first else { return }
        #expect(item.kind == .fee)
        #expect(item.kindConfidence >= 0.55)
    }
}
