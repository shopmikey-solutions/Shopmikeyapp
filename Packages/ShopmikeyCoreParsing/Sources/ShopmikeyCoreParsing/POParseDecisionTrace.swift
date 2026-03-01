//
//  POParseDecisionTrace.swift
//  POScannerApp
//

import Foundation

public struct POParseDecisionTrace: Hashable, Sendable {
    public struct RejectedLine: Hashable, Sendable {
        public let line: String
        public let reason: String

        public init(line: String, reason: String) {
            self.line = line
            self.reason = reason
        }
    }

    public let chosenProfile: POParser.DocumentProfile
    public let fallbackTriggered: Bool
    public let rejectedLines: [RejectedLine]

    public init(
        chosenProfile: POParser.DocumentProfile,
        fallbackTriggered: Bool,
        rejectedLines: [RejectedLine]
    ) {
        self.chosenProfile = chosenProfile
        self.fallbackTriggered = fallbackTriggered
        self.rejectedLines = rejectedLines
    }
}

final class POParseDecisionTraceRecorder {
    private var chosenProfile: POParser.DocumentProfile = .generic
    private var fallbackTriggered = false
    private var rejectedLines: [POParseDecisionTrace.RejectedLine] = []

    func setChosenProfile(_ profile: POParser.DocumentProfile) {
        chosenProfile = profile
    }

    func markFallbackTriggered() {
        fallbackTriggered = true
    }

    func recordRejectedLine(_ line: String, reason: String) {
        rejectedLines.append(.init(line: line, reason: reason))
    }

    func makeTrace() -> POParseDecisionTrace {
        POParseDecisionTrace(
            chosenProfile: chosenProfile,
            fallbackTriggered: fallbackTriggered,
            rejectedLines: rejectedLines
        )
    }
}
