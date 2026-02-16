//
//  String+VendorNormalization.swift
//  POScannerApp
//

import Foundation

extension String {
    var normalizedVendorName: String {
        let folded = trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        let punctuationCollapsed = folded.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: " ",
            options: .regularExpression
        )

        return punctuationCollapsed
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
