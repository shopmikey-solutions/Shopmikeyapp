//
//  TelemetryEvent.swift
//  POScannerApp
//

import Foundation

public struct TelemetryEvent: Codable, Hashable, Sendable {
    public let eventName: String
    public let timestamp: Date
    public let diagnosticCode: String?
    public let fallbackBranch: String?
    public let httpStatus: Int?
    public let durationMs: Int?
    public let context: [String: String]?

    public init(
        eventName: String,
        timestamp: Date = Date(),
        diagnosticCode: String? = nil,
        fallbackBranch: String? = nil,
        httpStatus: Int? = nil,
        durationMs: Int? = nil,
        context: [String: String]? = nil
    ) {
        self.eventName = eventName
        self.timestamp = timestamp
        self.diagnosticCode = diagnosticCode
        self.fallbackBranch = fallbackBranch
        self.httpStatus = httpStatus
        self.durationMs = durationMs
        self.context = context
    }
}

public struct TelemetryQueueSummary: Hashable, Sendable {
    public let isEnabled: Bool
    public let totalEvents: Int
    public let lastEventTimestamp: Date?
    public let countsByEventName: [String: Int]

    public init(
        isEnabled: Bool,
        totalEvents: Int,
        lastEventTimestamp: Date?,
        countsByEventName: [String: Int]
    ) {
        self.isEnabled = isEnabled
        self.totalEvents = totalEvents
        self.lastEventTimestamp = lastEventTimestamp
        self.countsByEventName = countsByEventName
    }

    public func topEventCounts(limit: Int = 5) -> [(eventName: String, count: Int)] {
        guard limit > 0 else { return [] }
        return countsByEventName
            .map { (eventName: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.eventName < rhs.eventName
                }
                return lhs.count > rhs.count
            }
            .prefix(limit)
            .map { $0 }
    }
}
