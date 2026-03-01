//
//  ParserArithmeticDiagnosticsReport.swift
//  POScannerApp
//

import Foundation

public struct ParserArithmeticDiagnosticsReport: Hashable, Sendable {
    public let lineItemCount: Int
    public let computedSubtotalCents: Int
    public let parsedTotalCents: Int?
    public let totalDeltaCents: Int
    public let zeroCostLineCount: Int
    public let defaultedQuantityLineCount: Int

    public var hasTotalMismatch: Bool {
        totalDeltaCents != 0
    }

    public init(
        lineItemCount: Int,
        computedSubtotalCents: Int,
        parsedTotalCents: Int?,
        totalDeltaCents: Int,
        zeroCostLineCount: Int,
        defaultedQuantityLineCount: Int
    ) {
        self.lineItemCount = lineItemCount
        self.computedSubtotalCents = computedSubtotalCents
        self.parsedTotalCents = parsedTotalCents
        self.totalDeltaCents = totalDeltaCents
        self.zeroCostLineCount = zeroCostLineCount
        self.defaultedQuantityLineCount = defaultedQuantityLineCount
    }
}
