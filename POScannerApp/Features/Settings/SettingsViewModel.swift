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

private let requireAuthPreferenceKey = "settings.requireAuthForToken"

@MainActor
final class SettingsViewModel: ObservableObject {
    let environment: AppEnvironment

    private var statusClearTask: Task<Void, Never>?

    @AppStorage("ignoreTaxAndTotals") var ignoreTaxAndTotals: Bool = false
    @AppStorage("experimentalOrderPOLinking") var experimentalOrderPOLinking: Bool = false
    @AppStorage(requireAuthPreferenceKey) var isBiometricRequired: Bool = false

    @Published var pastedKey: String = ""
    @Published var hasSavedKey: Bool = false
    @Published var isTestingConnection: Bool = false
    @Published var isRunningProbe: Bool = false
    @Published var statusMessage: String?
    @Published var endpointProbeReport: ShopmonkeyEndpointProbeReport?
    @Published var networkDiagnostics: [NetworkDiagnosticsEntry] = []

    init(environment: AppEnvironment) {
        self.environment = environment
        self.hasSavedKey = environment.keychainService.tokenExists()
        self.updateStatus()
    }

    func storeTokenFromInputIfNeeded() throws {
        let trimmed = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try environment.keychainService.storeToken(trimmed)
        hasSavedKey = environment.keychainService.tokenExists()
        pastedKey = ""
    }

    func saveKey() {
        let key = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setTransientStatus("Please paste a valid API key.")
            return
        }
        do {
            try environment.keychainService.storeToken(key)
            hasSavedKey = environment.keychainService.tokenExists()
            pastedKey = ""
            updateStatus()
        } catch {
            setTransientStatus("Unable to save API key.")
        }
    }

    func removeKey() {
        do {
            try environment.keychainService.deleteToken()
            hasSavedKey = environment.keychainService.tokenExists()
            updateStatus()
        } catch {
            setTransientStatus("Unable to remove API key.")
        }
    }

    func retrieveKeyForUse() async -> String? {
        if isBiometricRequired {
            do {
                return try await environment.secureStorage.retrieveTokenRequiringAuthentication()
            } catch let error as SecureStorage.SecureStorageError {
                switch error {
                case .userCancelled:
                    setTransientStatus("Cancelled")
                    return nil
                case .authenticationFailed, .biometricsUnavailable:
                    setTransientStatus("Authentication failed.")
                    return nil
                }
            } catch {
                setTransientStatus("Authentication failed.")
                return nil
            }
        } else {
            do {
                return try environment.keychainService.retrieveToken()
            } catch {
                setTransientStatus("No key available.")
                return nil
            }
        }
    }

    func updateStatus() {
        hasSavedKey = environment.keychainService.tokenExists()
        statusMessage = hasSavedKey ? "API key saved securely" : "No key saved"
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

    private func setTransientStatus(_ message: String, autoClearAfter seconds: Double = 3.0) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            let delayNanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            await MainActor.run {
                guard let self else { return }
                if self.statusMessage == message {
                    self.statusMessage = nil
                }
            }
        }
    }
}
