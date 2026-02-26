//
//  TelemetryQueue.swift
//  POScannerApp
//

import Foundation

actor TelemetryQueue {
    static let enabledPreferenceKey = "settings.telemetry.enabled"
    static let shared = TelemetryQueue()

    private struct PersistedTelemetryState: Codable {
        var events: [TelemetryEvent]
    }

    private static let forbiddenTerms: [String] = ["token", "authorization", "bearer"]
    private static let allowedContextKeys: Set<String> = [
        "source",
        "operation",
        "path",
        "endpoint",
        "route",
        "method",
        "mode",
        "trigger",
        "reason",
        "result",
        "statusGroup",
        "domain",
        "category"
    ]

    private let defaults: UserDefaults
    private let storageKey: String
    private let enabledKey: String
    private let maxEvents: Int
    private let maxStorageBytes: Int
    private var isEnabledState: Bool
    private var events: [TelemetryEvent]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "com.mikey.POScannerApp.telemetry.queue.v1",
        enabledKey: String = TelemetryQueue.enabledPreferenceKey,
        maxEvents: Int = 500,
        maxStorageBytes: Int = 256 * 1024
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.enabledKey = enabledKey
        self.maxEvents = max(1, maxEvents)
        self.maxStorageBytes = max(1_024, maxStorageBytes)
        self.isEnabledState = defaults.bool(forKey: enabledKey)
        self.events = Self.loadEvents(defaults: defaults, storageKey: storageKey)
    }

    func isEnabled() -> Bool {
        isEnabledState
    }

    func setEnabled(_ enabled: Bool, clearWhenDisabled: Bool = false) {
        isEnabledState = enabled
        defaults.set(enabled, forKey: enabledKey)

        if !enabled, clearWhenDisabled {
            clear()
        }
    }

    func enqueue(event: TelemetryEvent) {
        guard isEnabledState else { return }
        guard let safeEvent = sanitize(event: event) else { return }

        events.append(safeEvent)
        enforceLimits()
        persist()
    }

    func clear() {
        events.removeAll(keepingCapacity: false)
        defaults.removeObject(forKey: storageKey)
    }

    func snapshotSummary() -> TelemetryQueueSummary {
        let counts = events.reduce(into: [String: Int]()) { partialResult, event in
            partialResult[event.eventName, default: 0] += 1
        }
        return TelemetryQueueSummary(
            isEnabled: isEnabledState,
            totalEvents: events.count,
            lastEventTimestamp: events.last?.timestamp,
            countsByEventName: counts
        )
    }

    func nextBatch(limit: Int = 25) -> [TelemetryEvent] {
        guard limit > 0 else { return [] }
        return Array(events.prefix(limit))
    }

    func exportSummaryText(limit: Int = 10) -> String {
        let summary = snapshotSummary()
        let enabledLabel = summary.isEnabled ? "yes" : "no"
        let header = "Telemetry Summary\nEnabled: \(enabledLabel)\nEvents: \(summary.totalEvents)"

        let lastLine: String
        if let timestamp = summary.lastEventTimestamp {
            lastLine = "Last event: \(timestamp.formatted(date: .abbreviated, time: .shortened))"
        } else {
            lastLine = "Last event: n/a"
        }

        let topRows = summary.topEventCounts(limit: limit)
        if topRows.isEmpty {
            return "\(header)\n\(lastLine)\nTop events: none"
        }

        let topLines = topRows.map { "- \($0.eventName): \($0.count)" }.joined(separator: "\n")
        return "\(header)\n\(lastLine)\nTop events:\n\(topLines)"
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(PersistedTelemetryState(events: events))
            defaults.set(data, forKey: storageKey)
        } catch {
            // Telemetry persistence is best-effort only.
        }
    }

    private func enforceLimits() {
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }

        while estimatedStorageSize(for: events) > maxStorageBytes, !events.isEmpty {
            events.removeFirst()
        }
    }

    private func estimatedStorageSize(for events: [TelemetryEvent]) -> Int {
        guard let data = try? JSONEncoder().encode(PersistedTelemetryState(events: events)) else {
            return Int.max
        }
        return data.count
    }

    private func sanitize(event: TelemetryEvent) -> TelemetryEvent? {
        let sanitizedName = sanitizeScalar(event.eventName)
        guard !sanitizedName.isEmpty else { return nil }

        let diagnosticCode = sanitizeOptionalScalar(event.diagnosticCode)
        let fallbackBranch = sanitizeOptionalScalar(event.fallbackBranch)
        let httpStatus = sanitizeHTTPStatus(event.httpStatus)
        let durationMs = sanitizeDurationMs(event.durationMs)
        let context = sanitizeContext(event.context)

        return TelemetryEvent(
            eventName: sanitizedName,
            timestamp: event.timestamp,
            diagnosticCode: diagnosticCode,
            fallbackBranch: fallbackBranch,
            httpStatus: httpStatus,
            durationMs: durationMs,
            context: context
        )
    }

    private func sanitizeContext(_ context: [String: String]?) -> [String: String]? {
        guard let context, !context.isEmpty else { return nil }

        var safeContext: [String: String] = [:]
        for key in context.keys.sorted() {
            guard safeContext.count < 16 else { break }

            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.allowedContextKeys.contains(trimmedKey) else { continue }
            guard !containsForbiddenTerms(trimmedKey) else { continue }

            guard let value = context[key] else { continue }
            let sanitizedValue = sanitizeContextValue(value)
            guard !sanitizedValue.isEmpty else { continue }

            safeContext[trimmedKey] = sanitizedValue
        }

        return safeContext.isEmpty ? nil : safeContext
    }

    private func sanitizeContextValue(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        if let components = URLComponents(string: value),
           let scheme = components.scheme,
           let host = components.host {
            var sanitized = components
            sanitized.user = nil
            sanitized.password = nil
            sanitized.query = nil
            sanitized.fragment = nil
            if let cleaned = sanitized.string {
                value = cleaned
            } else {
                value = "\(scheme)://\(host)\(components.path)"
            }
        } else if let queryIndex = value.firstIndex(of: "?") {
            value = String(value[..<queryIndex])
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsForbiddenTerms(value) {
            return ""
        }

        return String(value.prefix(120))
    }

    private func sanitizeOptionalScalar(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = sanitizeScalar(value)
        return sanitized.isEmpty ? nil : sanitized
    }

    private func sanitizeScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !containsForbiddenTerms(trimmed) else { return "" }
        return String(trimmed.prefix(120))
    }

    private func sanitizeHTTPStatus(_ statusCode: Int?) -> Int? {
        guard let statusCode else { return nil }
        guard (100...599).contains(statusCode) else { return nil }
        return statusCode
    }

    private func sanitizeDurationMs(_ durationMs: Int?) -> Int? {
        guard let durationMs else { return nil }
        guard durationMs >= 0 else { return nil }
        return min(durationMs, 120_000)
    }

    private func containsForbiddenTerms(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return Self.forbiddenTerms.contains(where: { lowered.contains($0) })
    }

    private static func loadEvents(defaults: UserDefaults, storageKey: String) -> [TelemetryEvent] {
        guard let data = defaults.data(forKey: storageKey),
              let persisted = try? JSONDecoder().decode(PersistedTelemetryState.self, from: data) else {
            return []
        }
        return persisted.events
    }
}
