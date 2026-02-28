import Foundation

public struct FallbackEvent: Codable, Equatable, Sendable {
    public let code: String
    public let timestamp: Date
    public let context: String

    public init(code: String, timestamp: Date, context: String) {
        self.code = code
        self.timestamp = timestamp
        self.context = context
    }
}

public struct FallbackCounters: Codable, Equatable, Sendable {
    public var branchCounts: [String: Int] = [:]
    public var lastUsedBranch: String?
    public var lastUsedTimestamp: Date?

    public static let empty = FallbackCounters()

    public init(
        branchCounts: [String: Int] = [:],
        lastUsedBranch: String? = nil,
        lastUsedTimestamp: Date? = nil
    ) {
        self.branchCounts = branchCounts
        self.lastUsedBranch = lastUsedBranch
        self.lastUsedTimestamp = lastUsedTimestamp
    }

    public var totalEvents: Int {
        branchCounts.values.reduce(0, +)
    }

    public func topBranches(limit: Int = 5) -> [(branch: String, count: Int)] {
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

public enum FallbackBranch {
    public static let submitPrimaryEndpoint = "SUBMIT_PRIMARY_ENDPOINT"
    public static let submitAlternateEndpoint = "SUBMIT_ALTERNATE_ENDPOINT"
    public static let submitStatusFallback = "SUBMIT_STATUS_FALLBACK"
    public static let submitPayloadAttach = "SUBMIT_PAYLOAD_ATTACH"
    public static let submitPayloadQuickAdd = "SUBMIT_PAYLOAD_QUICKADD"
    public static let submitPayloadRestock = "SUBMIT_PAYLOAD_RESTOCK"
    public static let submitRetryPath = "SUBMIT_RETRY_PATH"
    public static let submitFallbackExhausted = "SUBMIT_FALLBACK_EXHAUSTED"
    public static let netRateLimitRetry = "NET_RATE_LIMIT_RETRY"
    public static let apiDecodeFallback = "API_DECODE_FALLBACK"
}
