//
//  SettingsViewModel.swift
//  POScannerApp
//

import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SettingsViewModel: ObservableObject {
    let environment: AppEnvironment

    @AppStorage("ignoreTaxAndTotals") var ignoreTaxAndTotals: Bool = false
    @AppStorage("experimentalOrderPOLinking") var experimentalOrderPOLinking: Bool = false

    @Published var apiKeyInput: String = ""
    @Published var isTestingConnection: Bool = false
    @Published var isRunningProbe: Bool = false
    @Published var statusMessage: String?
    @Published var endpointProbeReport: ShopmonkeyEndpointProbeReport?
    @Published var networkDiagnostics: [NetworkDiagnosticsEntry] = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func storeTokenFromInputIfNeeded() throws {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try environment.keychainService.storeToken(trimmed)
        apiKeyInput = ""
    }

    func testConnection() async {
        isTestingConnection = true
        statusMessage = nil

        do {
            try storeTokenFromInputIfNeeded()
            try await environment.shopmonkeyAPI.testConnection()
            statusMessage = "Shopmonkey connection verified for service-intake workflows."
        } catch {
            statusMessage = userMessage(for: error)
        }

        await refreshNetworkDiagnostics()
        isTestingConnection = false
    }

    func runEndpointProbe() async {
        isRunningProbe = true
        statusMessage = nil
        endpointProbeReport = nil

        do {
            try storeTokenFromInputIfNeeded()
            let report = try await environment.shopmonkeyAPI.runEndpointProbe()
            endpointProbeReport = report

            if report.createPurchaseOrderLikelySupported {
                statusMessage = "Probe complete: purchase-order read/search routes are reachable."
            } else {
                statusMessage = "Probe complete: purchase-order routes not fully confirmed."
            }
        } catch {
            statusMessage = userMessage(for: error)
        }

        await refreshNetworkDiagnostics()
        isRunningProbe = false
    }

    func refreshNetworkDiagnostics() async {
        networkDiagnostics = await environment.networkDiagnostics.latest(limit: 120)
    }

    func clearNetworkDiagnostics() async {
        await environment.networkDiagnostics.clear()
        networkDiagnostics = []
        statusMessage = "Network capture cleared."
    }

    func copyNetworkDiagnostics() async {
        let text = await environment.networkDiagnostics.exportText(limit: 200)
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        statusMessage = "Network capture copied."
        #else
        statusMessage = "Copy unavailable on this platform."
        #endif
    }
}
