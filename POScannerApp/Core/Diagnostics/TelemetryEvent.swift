//
//  TelemetryEvent.swift
//  POScannerApp
//

import Foundation

struct TelemetryEvent: Codable, Hashable {
    let eventName: String
    let timestamp: Date
    let diagnosticCode: String?
    let fallbackBranch: String?
    let httpStatus: Int?
    let durationMs: Int?
    let context: [String: String]?

    init(
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

struct TelemetryQueueSummary: Hashable {
    let isEnabled: Bool
    let totalEvents: Int
    let lastEventTimestamp: Date?
    let countsByEventName: [String: Int]

    func topEventCounts(limit: Int = 5) -> [(eventName: String, count: Int)] {
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
