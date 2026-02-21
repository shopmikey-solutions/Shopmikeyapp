//
//  AppDeepLinkTests.swift
//  POScannerAppTests
//

import Foundation
import Testing
@testable import POScannerApp

@Suite("Deep Link Parsing")
struct AppDeepLinkTests {
    @Test func parseScanCompose() {
        let url = DeepLinks.scan(compose: true)
        guard case let .scan(openComposer, draftID)? = AppDeepLink.parse(url) else {
            Issue.record("Expected scan route")
            return
        }
        #expect(openComposer == true)
        #expect(draftID == nil)
    }

    @Test func parseScanWithDraft() {
        let id = UUID()
        let url = DeepLinks.scan(draftID: id)
        guard case let .scan(openComposer, draftID)? = AppDeepLink.parse(url) else {
            Issue.record("Expected scan route with draft")
            return
        }
        #expect(openComposer == false)
        #expect(draftID == id)
    }

    @Test func parseHistoryAndSettings() {
        #expect(AppDeepLink.parse(DeepLinks.history) == .history)
        #expect(AppDeepLink.parse(DeepLinks.settings) == .settings)
    }

    @Test func parseUniversalLinks() {
        let id = UUID()
        let scanURL = URL(string: "https://shopmikey.app/scan?compose=1&draft=\(id.uuidString)")!
        let historyURL = URL(string: "https://shopmikey.app/history")!
        let settingsURL = URL(string: "https://shopmikey.app/settings")!

        #expect(AppDeepLink.parse(scanURL) == .scan(openComposer: true, draftID: id))
        #expect(AppDeepLink.parse(historyURL) == .history)
        #expect(AppDeepLink.parse(settingsURL) == .settings)
    }
}
