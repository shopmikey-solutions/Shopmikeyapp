//
//  TelemetryQueueTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct TelemetryQueueTests {
    private struct QueueHarness {
        let storageKey: String
        let enabledKey: String
        let queue: TelemetryQueue

        init(
            enabled: Bool,
            maxEvents: Int = 500,
            maxStorageBytes: Int = 256 * 1024
        ) {
            storageKey = "telemetry.queue.tests.\(UUID().uuidString)"
            enabledKey = "telemetry.enabled.tests.\(UUID().uuidString)"
            UserDefaults.standard.removeObject(forKey: storageKey)
            UserDefaults.standard.removeObject(forKey: enabledKey)
            UserDefaults.standard.set(enabled, forKey: enabledKey)
            queue = TelemetryQueue(
                storageKey: storageKey,
                enabledKey: enabledKey,
                maxEvents: maxEvents,
                maxStorageBytes: maxStorageBytes
            )
        }

        func cleanup() {
            UserDefaults.standard.removeObject(forKey: storageKey)
            UserDefaults.standard.removeObject(forKey: enabledKey)
        }

        func makeReloadedQueue() -> TelemetryQueue {
            TelemetryQueue(
                storageKey: storageKey,
                enabledKey: enabledKey
            )
        }

        func persistedData() -> Data? {
            UserDefaults.standard.data(forKey: storageKey)
        }
    }

    @Test func enqueueDoesNothingWhenTelemetryDisabled() async {
        let harness = QueueHarness(enabled: false)
        defer { harness.cleanup() }

        await harness.queue.enqueue(event: TelemetryEvent(eventName: "submission_attempted"))

        let summary = await harness.queue.snapshotSummary()
        #expect(summary.isEnabled == false)
        #expect(summary.totalEvents == 0)
        #expect(summary.countsByEventName.isEmpty)
    }

    @Test func enqueuePersistsWhenEnabled() async {
        let harness = QueueHarness(enabled: true)
        defer { harness.cleanup() }

        await harness.queue.enqueue(event: TelemetryEvent(eventName: "submission_attempted", httpStatus: 200))
        await harness.queue.enqueue(event: TelemetryEvent(eventName: "submission_succeeded", durationMs: 420))

        let summary = await harness.queue.snapshotSummary()
        #expect(summary.isEnabled == true)
        #expect(summary.totalEvents == 2)
        #expect(summary.countsByEventName["submission_attempted"] == 1)
        #expect(summary.countsByEventName["submission_succeeded"] == 1)

        let reloadedQueue = harness.makeReloadedQueue()
        let reloadedSummary = await reloadedQueue.snapshotSummary()
        #expect(reloadedSummary.totalEvents == 2)
        #expect(reloadedSummary.countsByEventName["submission_attempted"] == 1)
        #expect(reloadedSummary.countsByEventName["submission_succeeded"] == 1)
    }

    @Test func queueEvictsOldestEventsWhenMaxCountExceeded() async {
        let harness = QueueHarness(enabled: true, maxEvents: 3, maxStorageBytes: 128 * 1024)
        defer { harness.cleanup() }

        for index in 0..<5 {
            await harness.queue.enqueue(event: TelemetryEvent(eventName: "event_\(index)"))
        }

        let summary = await harness.queue.snapshotSummary()
        #expect(summary.totalEvents == 3)

        let batch = await harness.queue.nextBatch(limit: 10)
        #expect(batch.count == 3)
        #expect(batch.map(\.eventName) == ["event_2", "event_3", "event_4"])
    }

    @Test func redactionStripsSensitiveKeysValuesAndQueryParams() async {
        let harness = QueueHarness(enabled: true)
        defer { harness.cleanup() }

        await harness.queue.enqueue(
            event: TelemetryEvent(
                eventName: "diagnostic_snapshot",
                context: [
                    "source": "settings_view",
                    "endpoint": "https://api.shopmikey.local/v3/order?token=abc123",
                    "path": "/v3/order?authorization=secret",
                    "method": "POST",
                    "token": "abc123",
                    "reason": "Bearer abc123"
                ]
            )
        )

        let batch = await harness.queue.nextBatch(limit: 10)
        #expect(batch.count == 1)

        guard let context = batch.first?.context else {
            Issue.record("Expected sanitized telemetry context")
            return
        }

        #expect(context.keys.contains("token") == false)
        #expect(context.keys.contains("reason") == false)
        #expect(context["source"] == "settings_view")
        #expect(context["method"] == "POST")
        #expect(context["endpoint"] == "https://api.shopmikey.local/v3/order")
        #expect(context["path"] == "/v3/order")

        guard let persistedData = harness.persistedData() else {
            Issue.record("Expected telemetry queue to persist")
            return
        }

        let persistedRaw = String(decoding: persistedData, as: UTF8.self).lowercased()
        #expect(persistedRaw.contains("token") == false)
        #expect(persistedRaw.contains("authorization") == false)
        #expect(persistedRaw.contains("bearer") == false)
    }
}
