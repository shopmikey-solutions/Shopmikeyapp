//
//  ParserNoiseTaxonomyTests.swift
//  POScannerAppTests
//

import Testing
@testable import POScannerApp

struct ParserNoiseTaxonomyTests {
    @Test func parserAndHandoffReferenceCanonicalNoiseSets() {
        #expect(POParser.governanceStatusPrefixKeywords == ParserNoiseTaxonomy.ecommerceStatusPrefixKeywords)
        #expect(POParser.governanceStatusContainsKeywords == ParserNoiseTaxonomy.ecommerceStatusContainsKeywords)
        #expect(POParser.governanceLegalContainsKeywords == ParserNoiseTaxonomy.legalComplianceContainsKeywords)
        #expect(LocalParseHandoffService.governanceLowSignalKeywords == ParserNoiseTaxonomy.handoffLowSignalKeywords)
    }
}
