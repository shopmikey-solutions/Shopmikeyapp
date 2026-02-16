//
//  VendorSearchRankingTests.swift
//  POScannerAppTests
//

import Testing
@testable import POScannerApp

struct VendorSearchRankingTests {
    @Test func exactAndCanonicalMatchesRankHighest() async throws {
        let vendors = [
            VendorSummary(id: "v_1", name: "METRO AUTO PARTS SUPPLY LLC"),
            VendorSummary(id: "v_2", name: "Metro Auto Group"),
            VendorSummary(id: "v_3", name: "Completely Different")
        ]

        let ranked = VendorMatcher.rankVendors(vendors, query: "metro auto parts supply")
        #expect(!ranked.isEmpty)
        #expect(ranked.first?.vendor.id == "v_1")
        #expect((ranked.first?.score ?? 0) >= VendorMatcher.autoSelectScore)
    }

    @Test func noisyUnrelatedVendorsAreFilteredOut() async throws {
        let vendors = [
            VendorSummary(id: "v_1", name: "NAPA Auto Parts"),
            VendorSummary(id: "v_2", name: "Whelen"),
            VendorSummary(id: "v_3", name: "Fortin")
        ]

        let ranked = VendorMatcher.rankVendors(vendors, query: "mikey test unique vendor")
        #expect(ranked.isEmpty)
    }

    @Test func scoreUsesTokenOverlapForNearMatches() async throws {
        let score = VendorMatcher.score(query: "metro auto parts", candidate: "metro parts and supply")
        #expect(score >= VendorMatcher.minimumSuggestionScore)
        #expect(score < VendorMatcher.autoSelectScore)
    }
}
