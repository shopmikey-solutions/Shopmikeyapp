import Foundation
import ShopmikeyCoreModels
import Testing
import ShopmikeyCoreParsing
@testable import POScannerApp

struct ParserCorpusTests {
    @Test func parserCorpusFixturesMeetBaselineInvariants() throws {
        let fixtures = try ParserFixtureLoader.loadAll()
        #expect(!fixtures.isEmpty, "Parser corpus must include at least one fixture case.")

        let parser = POParser()

        for fixture in fixtures {
            let parsed = parser.parse(from: fixture.rawText)

            let context = failureContext(
                for: fixture,
                message: "Parser fixture invariant failed"
            )

            let shouldContainItems = containsItemLikeContent(fixture)
                || fixture.profile == .ecommerceCart
                || fixture.profile == .tabularInvoice
            if shouldContainItems {
                #expect(
                    !parsed.items.isEmpty,
                    "\(context)\nExpected at least one parsed line item for item-like fixture content."
                )
            }

            if let vendorHint = fixture.vendorHint?.trimmingCharacters(in: .whitespacesAndNewlines),
               !vendorHint.isEmpty {
                let vendorName = parsed.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(
                    vendorName == nil || !(vendorName?.isEmpty ?? false),
                    "\(context)\nVendor hint provided (\(vendorHint)); parser returned an empty vendor string."
                )
            }
        }
    }

    @Test func parserCorpusHasMinimumSeedCases() throws {
        let fixtures = try ParserFixtureLoader.loadAll()
        #expect(fixtures.count >= 2, "Parser corpus must keep at least 2 seed fixtures.")
    }

    private func containsItemLikeContent(_ fixture: ParserFixtureCase) -> Bool {
        if !fixture.rows.isEmpty {
            return true
        }

        let lower = fixture.rawText.lowercased()
        return lower.contains("qty")
            || lower.contains("part")
            || lower.contains("price")
            || lower.contains("subtotal")
            || lower.contains("total")
            || lower.contains("$")
    }

    private func failureContext(for fixture: ParserFixtureCase, message: String) -> String {
        let excerpt = fixture.rawText
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(200)
        return "\(message) | caseId=\(fixture.caseId) profile=\(fixture.profile.rawValue) excerpt=\"\(excerpt)\""
    }
}
