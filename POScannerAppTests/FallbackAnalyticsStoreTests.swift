//
//  FallbackAnalyticsStoreTests.swift
//  POScannerAppTests
//

import Foundation
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct FallbackAnalyticsStoreTests {
    private struct StoreHarness {
        let suiteName: String
        let storageKey: String
        let defaults: UserDefaults
        let store: FallbackAnalyticsStore

        init() {
            suiteName = "FallbackAnalyticsStoreTests.\(UUID().uuidString)"
            storageKey = "fallback_analytics_test_\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = FallbackAnalyticsStore(defaults: defaults, storageKey: storageKey)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test func recordingIncrementsCountersDeterministically() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        await harness.store.record(branch: FallbackBranch.submitPrimaryEndpoint)
        await harness.store.record(branch: FallbackBranch.submitPrimaryEndpoint)
        await harness.store.record(branch: FallbackBranch.submitStatusFallback)

        let snapshot = await harness.store.snapshot()
        #expect(snapshot.totalEvents == 3)
        #expect(snapshot.branchCounts[FallbackBranch.submitPrimaryEndpoint] == 2)
        #expect(snapshot.branchCounts[FallbackBranch.submitStatusFallback] == 1)
    }

    @Test func lastUsedBranchUpdates() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        await harness.store.record(branch: FallbackBranch.submitPrimaryEndpoint)
        await harness.store.record(branch: FallbackBranch.submitAlternateEndpoint)

        let snapshot = await harness.store.snapshot()
        #expect(snapshot.lastUsedBranch == FallbackBranch.submitAlternateEndpoint)
        #expect(snapshot.lastUsedTimestamp != nil)
    }

    @Test func persistenceSurvivesReinitialization() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        await harness.store.record(branch: FallbackBranch.submitRetryPath)
        await harness.store.record(branch: FallbackBranch.submitRetryPath)

        let reloadedStore = FallbackAnalyticsStore(defaults: harness.defaults, storageKey: harness.storageKey)
        let snapshot = await reloadedStore.snapshot()

        #expect(snapshot.totalEvents == 2)
        #expect(snapshot.branchCounts[FallbackBranch.submitRetryPath] == 2)
        #expect(snapshot.lastUsedBranch == FallbackBranch.submitRetryPath)
    }

    @Test func clearResetsAllCounters() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        await harness.store.record(branch: FallbackBranch.submitPayloadAttach)
        await harness.store.clear()

        let snapshot = await harness.store.snapshot()
        #expect(snapshot.totalEvents == 0)
        #expect(snapshot.branchCounts.isEmpty)
        #expect(snapshot.lastUsedBranch == nil)
        #expect(snapshot.lastUsedTimestamp == nil)
        #expect(harness.defaults.data(forKey: harness.storageKey) == nil)
    }

    @Test func persistedDataDoesNotContainSensitiveStrings() async {
        let harness = StoreHarness()
        defer { harness.cleanup() }

        await harness.store.record(
            branch: FallbackBranch.netRateLimitRetry,
            context: "Authorization: Bearer token_value"
        )

        guard let persistedData = harness.defaults.data(forKey: harness.storageKey) else {
            Issue.record("Expected fallback analytics data to persist")
            return
        }

        let persisted = String(decoding: persistedData, as: UTF8.self)
        #expect(persisted.contains(FallbackBranch.netRateLimitRetry))
        #expect(persisted.localizedCaseInsensitiveContains("token") == false)
        #expect(persisted.localizedCaseInsensitiveContains("authorization") == false)
    }
}
