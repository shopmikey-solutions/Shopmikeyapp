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

    @Test func confidenceIsHighForExactMatch() async throws {
        let vendors = [
            VendorSummary(id: "v_1", name: "Metro Auto Parts Supply")
        ]

        let ranked = VendorMatcher.rankVendors(vendors, query: "metro auto parts supply")
        #expect(ranked.first?.confidence == .high)
    }

    @Test func confidenceIsMediumForStrongFuzzyMatch() async throws {
        let vendors = [
            VendorSummary(id: "v_1", name: "Metro Parts Supply")
        ]

        let ranked = VendorMatcher.rankVendors(vendors, query: "metro auto parts")
        #expect(ranked.first?.score ?? 0 >= VendorMatcher.mediumSuggestionScore)
        #expect(ranked.first?.score ?? 0 < VendorMatcher.autoSelectScore)
        #expect(ranked.first?.confidence == .medium)
    }

    @Test func confidenceIsLowForWeakFuzzyMatch() async throws {
        let vendors = [
            VendorSummary(id: "v_1", name: "Metro Truck Center")
        ]

        let ranked = VendorMatcher.rankVendors(vendors, query: "metro auto parts")
        #expect(ranked.first?.score ?? 0 >= VendorMatcher.minimumSuggestionScore)
        #expect(ranked.first?.score ?? 0 < VendorMatcher.mediumSuggestionScore)
        #expect(ranked.first?.confidence == .low)
    }

    @Test func confidenceIsMismatchForExplicitConflict() async throws {
        let top = RankedVendorMatch(
            vendor: VendorSummary(id: "v_1", name: "Metro Auto Parts Supply"),
            score: 0.96
        )

        let confidence = VendorMatcher.confidence(
            for: top,
            selectedVendorID: "v_1",
            inferredVendorName: "Metro Auto Parts Supply",
            selectedVendorName: "Alpha Tire Warehouse"
        )
        #expect(confidence == .mismatch)
    }

    @Test func highConfidenceDoesNotTriggerMismatchWarning() async throws {
        let warning = VendorMatcher.shouldShowMismatchWarning(
            confidence: .high,
            inferredVendorName: "Metro Auto Parts Supply",
            selectedVendorName: "Metro Auto Parts Supply LLC"
        )
        #expect(warning == false)
    }

    @Test func mismatchTriggersWarning() async throws {
        let warning = VendorMatcher.shouldShowMismatchWarning(
            confidence: .mismatch,
            inferredVendorName: "Metro Auto Parts Supply",
            selectedVendorName: "Alpha Tire Warehouse"
        )
        #expect(warning == true)
    }
}
