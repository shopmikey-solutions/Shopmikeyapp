//
//  FallbackAnalyticsStore.swift
//  POScannerApp
//

import Foundation

struct FallbackEvent: Codable, Equatable {
    let code: String
    let timestamp: Date
    let context: String
}

struct FallbackCounters: Codable, Equatable {
    var branchCounts: [String: Int] = [:]
    var lastUsedBranch: String?
    var lastUsedTimestamp: Date?

    static let empty = FallbackCounters()

    var totalEvents: Int {
        branchCounts.values.reduce(0, +)
    }

    func topBranches(limit: Int = 5) -> [(branch: String, count: Int)] {
        guard limit > 0 else { return [] }
        return branchCounts
            .map { (branch: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.branch < rhs.branch
                }
                return lhs.count > rhs.count
            }
            .prefix(limit)
            .map { $0 }
    }
}

enum FallbackBranch {
    static let submitPrimaryEndpoint = "SUBMIT_PRIMARY_ENDPOINT"
    static let submitAlternateEndpoint = "SUBMIT_ALTERNATE_ENDPOINT"
    static let submitStatusFallback = "SUBMIT_STATUS_FALLBACK"
    static let submitPayloadAttach = "SUBMIT_PAYLOAD_ATTACH"
    static let submitPayloadQuickAdd = "SUBMIT_PAYLOAD_QUICKADD"
    static let submitPayloadRestock = "SUBMIT_PAYLOAD_RESTOCK"
    static let submitRetryPath = "SUBMIT_RETRY_PATH"
    static let submitFallbackExhausted = "SUBMIT_FALLBACK_EXHAUSTED"
    static let netRateLimitRetry = "NET_RATE_LIMIT_RETRY"
    static let apiDecodeFallback = "API_DECODE_FALLBACK"
}

actor FallbackAnalyticsStore {
    static let shared = FallbackAnalyticsStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private var counters: FallbackCounters
    private(set) var lastEvent: FallbackEvent?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "com.mikey.POScannerApp.fallback_analytics.counters.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.counters = Self.loadCounters(defaults: defaults, storageKey: storageKey)
    }

    func record(branch: String, context: String = "") {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return }

        counters.branchCounts[trimmedBranch, default: 0] += 1
        counters.lastUsedBranch = trimmedBranch
        counters.lastUsedTimestamp = Date()

        lastEvent = FallbackEvent(
            code: trimmedBranch,
            timestamp: counters.lastUsedTimestamp ?? Date(),
            context: sanitizedContext(context)
        )

        persist(counters)
    }

    func snapshot() -> FallbackCounters {
        counters
    }

    func clear() {
        counters = .empty
        lastEvent = nil
        defaults.removeObject(forKey: storageKey)
    }

    private static func loadCounters(defaults: UserDefaults, storageKey: String) -> FallbackCounters {
        guard let data = defaults.data(forKey: storageKey) else {
            return .empty
        }
        do {
            return try JSONDecoder().decode(FallbackCounters.self, from: data)
        } catch {
            return .empty
        }
    }

    private func persist(_ counters: FallbackCounters) {
        do {
            let data = try JSONEncoder().encode(counters)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Non-critical diagnostics storage should never interrupt app flow.
        }
    }

    private func sanitizedContext(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "n/a" }
        return String(trimmed.prefix(120))
    }
}
