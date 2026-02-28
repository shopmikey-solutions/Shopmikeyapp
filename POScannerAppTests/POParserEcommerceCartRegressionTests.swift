//
//  POParserEcommerceCartRegressionTests.swift
//  POScannerAppTests
//

import Testing
import ShopmikeyCoreModels
import Foundation
@testable import POScannerApp

struct POParserEcommerceCartRegressionTests {
    @Test func avoidsCheckoutRailLeakageIntoCartLineItems() throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        MY CART (11)
        2016 Subaru Outback
        Denso Iridium TT Spark Plug - 4704
        Part # 4704 Line DEN Item Subtotal $863.89
        - 6 + REMOVE
        $77.94
        Ultima 130 Amp Alternator - Remanufactured - R113721
        Part # R113721 Line ULT EST. TOTAL $850.90 Code APPLY
        - 1 + REMOVE
        $284.99
        + Refundable Core $40.00
        BrakeBest Select Front Brake Rotor - 980377RGS
        Part # 980377RGS Line BBR Tax Calculated at Checkout
        - 2 + REMOVE
        $203.79
        BrakeBest Select Front Ceramic Brake Pads - SC1078
        Part # SC1078 Line BB Reg. $62.09 Available payment methods in checkout:
        - 1 + REMOVE
        $52.19
        Non Vehicle Specific
        Murray Tensioners Drive Belt Tensioner - 2336036
        Part # 2336036 Line MRY
        - 1 + REMOVE
        $191.99
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.count >= 5)

        guard let sparkPlug = parsed.items.first(where: { ($0.partNumber ?? "") == "4704" }) else {
            Issue.record("Missing spark plug row")
            return
        }
        #expect(sparkPlug.quantity == 6)
        #expect(sparkPlug.costCents == 1299)

        guard let alternator = parsed.items.first(where: { ($0.partNumber ?? "") == "R113721" }) else {
            Issue.record("Missing alternator row")
            return
        }
        #expect(alternator.quantity == 1)
        #expect(alternator.costCents == 28499)

        guard let rotor = parsed.items.first(where: { ($0.partNumber ?? "") == "980377RGS" }) else {
            Issue.record("Missing rotor row")
            return
        }
        #expect(rotor.quantity == 2)
        #expect(rotor.costCents == 10190)

        guard let brakePads = parsed.items.first(where: { ($0.partNumber ?? "") == "SC1078" }) else {
            Issue.record("Missing brake pads row")
            return
        }
        #expect(brakePads.quantity == 1)
        #expect(brakePads.costCents == 5219)

        guard let tensioner = parsed.items.first(where: { ($0.partNumber ?? "") == "2336036" }) else {
            Issue.record("Missing tensioner row")
            return
        }
        #expect(tensioner.quantity == 1)
        #expect(tensioner.costCents == 19199)

        #expect(!parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("calculated at checkout") }))
        #expect(!parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("available payment methods") }))
        #expect(!parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("code apply") }))
    }
}
