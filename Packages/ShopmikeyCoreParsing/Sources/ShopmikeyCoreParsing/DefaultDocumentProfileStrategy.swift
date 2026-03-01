//
//  DefaultDocumentProfileStrategy.swift
//  POScannerApp
//

import Foundation

struct DefaultDocumentProfileStrategy {
    func resolveProfile(
        for lines: [String],
        hasStepperQuantityControlSignal: (String) -> Bool,
        isEcommercePartAnchorLine: (String) -> Bool,
        isLikelyEcommerceStatusLine: (String) -> Bool,
        isTableHeaderLine: (String) -> Bool,
        monetaryTokenCount: (String) -> Int
    ) -> POParser.DocumentProfile {
        guard !lines.isEmpty else { return .generic }

        let stepperSignals = lines.filter { hasStepperQuantityControlSignal($0) }.count
        let partAnchorSignals = lines.filter { isEcommercePartAnchorLine($0) }.count
        let ecommerceStatusSignals = lines.filter { isLikelyEcommerceStatusLine($0) }.count
        let tableHeaderSignals = lines.filter { isTableHeaderLine($0) }.count
        let multiPriceSignals = lines.filter { monetaryTokenCount($0) >= 2 }.count

        if stepperSignals >= 1 && (partAnchorSignals >= 1 || ecommerceStatusSignals >= 2) {
            return .ecommerceCart
        }
        if partAnchorSignals >= 2 && ecommerceStatusSignals >= 2 {
            return .ecommerceCart
        }
        if tableHeaderSignals >= 1 || multiPriceSignals >= 2 {
            return .tabularInvoice
        }
        return .generic
    }
}
