//
//  LocalParseHandoffServiceTests.swift
//  POScannerAppTests
//

import Testing
import Foundation
@testable import POScannerApp

struct LocalParseHandoffServiceTests {
    @Test func preservesDuplicateQuantityStepperRowsForCarts() {
        let service = LocalParseHandoffService()
        let payload = service.build(
            reviewedText: """
            Part # R113721 Line ULT
            - 1 + REMOVE
            $284.99
            Part # SC1078 Line BB
            - 1 + REMOVE
            $52.19
            """,
            barcodeHints: []
        )

        let stepperCount = payload.rulesInputText
            .components(separatedBy: "\n")
            .filter { $0.localizedCaseInsensitiveContains("- 1 +") }
            .count

        #expect(stepperCount == 2)
        #expect(payload.metrics.deduplicatedLineCount == 6)
    }

    @Test func deduplicatesRepeatedLowSignalBoilerplateLines() {
        let service = LocalParseHandoffService()
        let payload = service.build(
            reviewedText: """
            FREE Pick Up
            FREE Pick Up
            FREE Pick Up
            Part # 980377RGS Line BBR
            - 2 + REMOVE
            $203.79
            """,
            barcodeHints: []
        )

        let freePickupCount = payload.rulesInputText
            .components(separatedBy: "\n")
            .filter { $0.localizedCaseInsensitiveContains("free pick up") }
            .count

        #expect(freePickupCount == 1)
        #expect(payload.rulesInputText.contains("Part # 980377RGS"))
    }
}
