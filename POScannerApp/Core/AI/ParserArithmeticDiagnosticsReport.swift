//
//  ParserArithmeticDiagnosticsReport.swift
//  POScannerApp
//

import Foundation

struct ParserArithmeticDiagnosticsReport: Hashable {
    let lineItemCount: Int
    let computedSubtotalCents: Int
    let parsedTotalCents: Int?
    let totalDeltaCents: Int
    let zeroCostLineCount: Int
    let defaultedQuantityLineCount: Int

    var hasTotalMismatch: Bool {
        totalDeltaCents != 0
    }
}
