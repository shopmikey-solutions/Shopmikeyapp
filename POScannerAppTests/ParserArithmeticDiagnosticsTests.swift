//
//  ParserArithmeticDiagnosticsTests.swift
//  POScannerAppTests
//

import Testing
import ShopmikeyCoreModels
@testable import POScannerApp

struct ParserArithmeticDiagnosticsTests {
    @Test func diagnosticsModeDoesNotChangeParserOutput() {
        let fixture = """
        METRO AUTO PARTS SUPPLY
        Invoice #: PO-99012 PO Number: MAP-45821
        ACD-41-993 Front Brake Pad Set - Ceramic 6 $68.00 $408.00
        MOOG-K750012 Front Sway Bar Link Kit 4 $45.00 $180.00
        FRM-PH7317 Engine Oil Filter 12 $9.50 $114.00
        """

        let baselineParser = POParser()
        let baseline = baselineParser.parse(from: fixture, ignoreTaxAndTotals: true)
        #expect(baselineParser.latestArithmeticDiagnosticsReport == nil)

        let diagnosticsParser = POParser()
        diagnosticsParser.arithmeticDiagnosticsEnabled = true
        let diagnosticsResult = diagnosticsParser.parse(from: fixture, ignoreTaxAndTotals: true)

        #expect(diagnosticsResult == baseline)

        guard let report = diagnosticsParser.latestArithmeticDiagnosticsReport else {
            Issue.record("Expected arithmetic diagnostics report")
            return
        }
        #expect(report.lineItemCount == diagnosticsResult.items.count)
        #expect(report.computedSubtotalCents == (diagnosticsResult.totalCents ?? 0))
        #expect(report.hasTotalMismatch == false)
    }
}
