//
//  VendorMatching.swift
//  POScannerApp
//

import Foundation

struct RankedVendorMatch {
    let vendor: VendorSummary
    let score: Double
}

enum VendorMatcher {
    static let minimumSuggestionScore: Double = 0.55
    static let autoSelectScore: Double = 0.80

    static func rankVendors(
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

    static func score(query: String, candidate: String) -> Double {
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

    static func canonicalVendorName(_ raw: String) -> String {
        let normalized = raw.normalizedVendorName
        guard !normalized.isEmpty else { return "" }

        var tokens = normalized.split(separator: " ").map(String.init)
        while tokens.count > 1, let tail = tokens.last, legalSuffixes.contains(tail) {
            tokens.removeLast()
        }

        return tokens.joined(separator: " ")
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
