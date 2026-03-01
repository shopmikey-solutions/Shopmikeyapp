//
//  VendorMatching.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

public enum VendorMatchConfidence: String {
    case high
    case medium
    case low
    case mismatch
}

public struct RankedVendorMatch {
    public let vendor: VendorSummary
    public let score: Double

    public init(vendor: VendorSummary, score: Double) {
        self.vendor = vendor
        self.score = score
    }

    public var confidence: VendorMatchConfidence {
        if score >= VendorMatcher.autoSelectScore {
            return .high
        }
        if score >= VendorMatcher.mediumSuggestionScore {
            return .medium
        }
        return .low
    }
}

public enum VendorMatcher {
    public static let minimumSuggestionScore: Double = 0.55
    public static let mediumSuggestionScore: Double = 0.74
    public static let autoSelectScore: Double = 0.80

    public static func rankVendors(
        _ vendors: [VendorSummary],
        query: String,
        minimumScore: Double = minimumSuggestionScore
    ) -> [RankedVendorMatch] {
        let normalizedQuery = query.normalizedVendorName
        guard !normalizedQuery.isEmpty else { return [] }

        var bestByNormalized: [String: RankedVendorMatch] = [:]

        for vendor in vendors {
            let normalizedCandidate = vendor.name.normalizedVendorName
            guard !normalizedCandidate.isEmpty else { continue }

            let score = score(query: normalizedQuery, candidate: normalizedCandidate)
            guard score >= minimumScore else { continue }

            let next = RankedVendorMatch(vendor: vendor, score: score)
            if let existing = bestByNormalized[normalizedCandidate], existing.score >= next.score {
                continue
            }
            bestByNormalized[normalizedCandidate] = next
        }

        return bestByNormalized.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.vendor.name.localizedCaseInsensitiveCompare(rhs.vendor.name) == .orderedAscending
        }
    }

    public static func score(query: String, candidate: String) -> Double {
        let normalizedQuery = query.normalizedVendorName
        let normalizedCandidate = candidate.normalizedVendorName
        guard !normalizedQuery.isEmpty, !normalizedCandidate.isEmpty else { return 0 }

        if normalizedQuery == normalizedCandidate {
            return 1.0
        }

        let canonicalQuery = canonicalVendorName(normalizedQuery)
        let canonicalCandidate = canonicalVendorName(normalizedCandidate)
        if !canonicalQuery.isEmpty, canonicalQuery == canonicalCandidate {
            return 0.96
        }

        var score = 0.0

        if normalizedCandidate.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(normalizedCandidate) {
            score = max(score, 0.88)
        }

        if canonicalCandidate.hasPrefix(canonicalQuery) || canonicalQuery.hasPrefix(canonicalCandidate) {
            score = max(score, 0.84)
        }

        if normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate) {
            score = max(score, 0.66)
        }

        let queryTokens = Set(canonicalQuery.split(separator: " ").map(String.init))
        let candidateTokens = Set(canonicalCandidate.split(separator: " ").map(String.init))
        if !queryTokens.isEmpty, !candidateTokens.isEmpty {
            let overlap = queryTokens.intersection(candidateTokens).count
            if overlap > 0 {
                let denominator = max(queryTokens.count, candidateTokens.count)
                let tokenScore = Double(overlap) / Double(denominator)
                score = max(score, 0.55 + (tokenScore * 0.35))
            }
        }

        return min(1.0, score)
    }

    public static func canonicalVendorName(_ raw: String) -> String {
        let normalized = raw.normalizedVendorName
        guard !normalized.isEmpty else { return "" }

        var tokens = normalized.split(separator: " ").map(String.init)
        while tokens.count > 1, let tail = tokens.last, legalSuffixes.contains(tail) {
            tokens.removeLast()
        }

        return tokens.joined(separator: " ")
    }

    public static func confidence(
        for topMatch: RankedVendorMatch?,
        selectedVendorID: String?,
        inferredVendorName: String?,
        selectedVendorName: String?
    ) -> VendorMatchConfidence {
        if isMaterialMismatch(
            inferredVendorName: inferredVendorName,
            selectedVendorName: selectedVendorName
        ) {
            return .mismatch
        }

        guard let topMatch else { return .low }
        if let selectedVendorID, selectedVendorID == topMatch.vendor.id {
            return .high
        }
        return topMatch.confidence
    }

    public static func shouldShowMismatchWarning(
        confidence: VendorMatchConfidence,
        inferredVendorName: String?,
        selectedVendorName: String?
    ) -> Bool {
        guard confidence == .mismatch || confidence == .low else { return false }
        return isMaterialMismatch(
            inferredVendorName: inferredVendorName,
            selectedVendorName: selectedVendorName
        )
    }

    public static func isMaterialMismatch(
        inferredVendorName: String?,
        selectedVendorName: String?
    ) -> Bool {
        let inferredCanonical = canonicalVendorName(inferredVendorName ?? "")
        let selectedCanonical = canonicalVendorName(selectedVendorName ?? "")
        guard !inferredCanonical.isEmpty, !selectedCanonical.isEmpty else { return false }
        guard inferredCanonical != selectedCanonical else { return false }

        let inferredNormalized = inferredVendorName?.normalizedVendorName ?? inferredCanonical
        let selectedNormalized = selectedVendorName?.normalizedVendorName ?? selectedCanonical
        let similarity = score(query: inferredNormalized, candidate: selectedNormalized)
        return similarity < mediumSuggestionScore
    }

    private static let legalSuffixes: Set<String> = [
        "inc",
        "incorporated",
        "llc",
        "ltd",
        "limited",
        "co",
        "corp",
        "corporation",
        "company",
        "plc"
    ]
}
