//
//  POParseDecisionTrace.swift
//  POScannerApp
//

import Foundation

struct POParseDecisionTrace: Hashable {
    struct RejectedLine: Hashable {
        let line: String
        let reason: String
    }

    let chosenProfile: POParser.DocumentProfile
    let fallbackTriggered: Bool
    let rejectedLines: [RejectedLine]
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
