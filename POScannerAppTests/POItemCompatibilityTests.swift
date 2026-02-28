//
//  POItemCompatibilityTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

struct POItemCompatibilityTests {
    @Test func decodesLegacyItemWithoutKindFields() throws {
        let json = """
        {
          "id": "A2F9329C-5DDE-4B91-91D2-9B7FFCE4B0B7",
          "description": "Front Brake Pad Set",
          "quantity": 2,
          "unitCost": 68.0,
          "confidence": 0.84
        }
        """

        let item = try JSONDecoder().decode(POItem.self, from: Data(json.utf8))

        #expect(item.description == "Front Brake Pad Set")
        #expect(item.quantity == 2)
        #expect(item.costCents == 6800)
        #expect(item.kind == .unknown)
        #expect(item.kindConfidence == 0)
        #expect(item.kindReasons.isEmpty)
    }

    @Test func decodesLegacyNameAndCostKeys() throws {
        let json = """
        {
          "name": "Engine Oil Filter",
          "quantity": 3,
          "cost": 9.5
        }
        """

        let item = try JSONDecoder().decode(POItem.self, from: Data(json.utf8))

        #expect(item.description == "Engine Oil Filter")
        #expect(item.quantity == 3)
        #expect(item.costCents == 950)
        #expect(item.kind == .unknown)
    }

    @Test func decodesUnknownKindAsUnknown() throws {
        let json = """
        {
          "description": "Shop Supplies",
          "quantity": 1,
          "unitCost": 12.0,
          "kind": "service_fee"
        }
        """

        let item = try JSONDecoder().decode(POItem.self, from: Data(json.utf8))

        #expect(item.kind == .unknown)
        #expect(item.kindConfidence == 0)
    }

    @Test func feeInferenceHintExtractsServiceReason() throws {
        let item = POItem(
            name: "Mount and Balance Service",
            quantity: 1,
            cost: 120,
            kind: .fee,
            kindConfidence: 0.72,
            kindReasons: ["contains fee term 'mount and balance'"]
        )

        #expect(item.feeInferenceHint == "Fee inferred: mount and balance")
    }

    @Test func feeInferenceHintSkipsNonServiceFeeReasons() throws {
        let item = POItem(
            name: "Shipping Freight",
            quantity: 1,
            cost: 20,
            kind: .fee,
            kindConfidence: 0.72,
            kindReasons: ["contains fee term 'shipping'"]
        )

        #expect(item.feeInferenceHint == nil)
    }
}
