import Foundation
import Testing
@testable import POScannerApp

struct ParserGoldenTests {
    @Test func parserCorpusMatchesCanonicalGoldens() throws {
        let fixtures = try ParserFixtureLoader.loadAll()
        #expect(!fixtures.isEmpty, "Parser corpus must include at least one fixture case for golden validation.")

        let parser = POParser()

        for fixture in fixtures {
            let parsed = parser.parse(from: fixture.rawText)
            let snapshot = ParserGoldenSnapshot(caseId: fixture.caseId, profile: fixture.profile, parsed: parsed)

            do {
                try ParserGoldenComparator.assertGolden(caseId: fixture.caseId, actualModel: snapshot)
            } catch {
                let excerpt = fixture.rawText.replacingOccurrences(of: "\n", with: " ").prefix(200)
                Issue.record(
                    "Parser golden assertion failed | caseId=\(fixture.caseId) profile=\(fixture.profile.rawValue) excerpt=\"\(excerpt)\"\n\(error.localizedDescription)"
                )
                throw error
            }
        }
    }
}

private struct ParserGoldenSnapshot: Codable {
    struct Document: Codable {
        var vendorName: String?
        var poNumber: String?
        var invoiceNumber: String?
    }

    struct Totals: Codable {
        var subtotalCents: Int?
        var taxCents: Int?
        var totalCents: Int?
    }

    struct LineItem: Codable {
        var description: String
        var partNumber: String?
        var quantity: Int?
        var unitPriceCents: Int?
        var extendedPriceCents: Int?
        var type: String
    }

    var schemaVersion: Int
    var caseId: String
    var profile: String
    var document: Document
    var lineItems: [LineItem]
    var totals: Totals

    init(caseId: String, profile: ParserFixtureProfile, parsed: ParsedInvoice) {
        self.schemaVersion = 1
        self.caseId = caseId
        self.profile = profile.rawValue
        self.document = Document(
            vendorName: parsed.vendorName,
            poNumber: parsed.poNumber,
            invoiceNumber: parsed.invoiceNumber
        )
        self.lineItems = parsed.items.map { item in
            let quantity = item.quantity
            let unitPrice = item.costCents
            let extendedPrice: Int?
            if let quantity, let unitPrice {
                extendedPrice = quantity * unitPrice
            } else {
                extendedPrice = nil
            }

            return LineItem(
                description: item.name,
                partNumber: item.partNumber,
                quantity: quantity,
                unitPriceCents: unitPrice,
                extendedPriceCents: extendedPrice,
                type: item.kind.rawValue
            )
        }
        self.totals = Totals(
            subtotalCents: parsed.totalCents,
            taxCents: nil,
            totalCents: parsed.totalCents
        )
    }
}
