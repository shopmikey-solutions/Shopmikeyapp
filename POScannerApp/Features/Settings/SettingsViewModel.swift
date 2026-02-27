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
    enum KeyAction: Equatable {
        case saving
        case authorizingEdit
        case verifying
        case revealing
        case copying
        case removing
    }

    struct FallbackBranchCount: Identifiable, Hashable {
        let branch: String
        let count: Int

        var id: String { branch }
    }

    struct TelemetryEventCount: Identifiable, Hashable {
        let eventName: String
        let count: Int

        var id: String { eventName }
    }

    let environment: AppEnvironment

    private var keyStatusClearTask: Task<Void, Never>?
    private var keyRevealClearTask: Task<Void, Never>?
    private var clipboardClearTask: Task<Void, Never>?

    @AppStorage("ignoreTaxAndTotals") var ignoreTaxAndTotals: Bool = false
    @AppStorage("experimentalOrderPOLinking") var experimentalOrderPOLinking: Bool = false
    @AppStorage("settings.requireAuthForToken") var isBiometricRequired: Bool = false
    @AppStorage(TelemetryQueue.enabledPreferenceKey) var isTelemetryEnabled: Bool = false

    @Published var pastedKey: String = ""
    @Published var hasSavedKey: Bool = false
    @Published var isTestingConnection: Bool = false
    @Published var isRunningProbe: Bool = false
    @Published var revealedAPIKey: String?
    @Published private(set) var activeKeyAction: KeyAction?
    @Published var keyStatusMessage: String?
    @Published var connectivityStatusMessage: String?
    @Published var endpointProbeReport: ShopmonkeyEndpointProbeReport?
    @Published var networkDiagnostics: [NetworkDiagnosticsEntry] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastDiagnosticCode: DiagnosticCode?

    var lastDiagnosticID: String? {
        lastDiagnosticCode?.rawValue
    }

    var formattedLastErrorMessage: String? {
        guard let lastErrorMessage, let lastDiagnosticID else { return nil }
        return "Error: \(lastErrorMessage) (ID: \(lastDiagnosticID))"
    }
    @Published var fallbackAnalyticsTotalEvents: Int = 0
    @Published var fallbackAnalyticsTopBranches: [FallbackBranchCount] = []
    @Published var fallbackAnalyticsLastBranch: String?
    @Published var fallbackAnalyticsLastTimestamp: Date?
    @Published var telemetryTotalEvents: Int = 0
    @Published var telemetryLastEventTimestamp: Date?
    @Published var telemetryTopEvents: [TelemetryEventCount] = []

    init(environment: AppEnvironment) {
        self.environment = environment
        self.hasSavedKey = environment.keychainService.tokenExists()
        self.updateStatus()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshFallbackAnalytics()
            await self.setTelemetryEnabled(self.isTelemetryEnabled, clearWhenDisabled: false)
        }
    }

    func storeTokenFromInputIfNeeded() throws {
        let trimmed = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try environment.keychainService.storeToken(trimmed)
        hasSavedKey = environment.keychainService.tokenExists()
        pastedKey = ""
    }

    func saveKey() {
        guard beginKeyAction(.saving) else { return }
        defer { endKeyAction(.saving) }

        let key = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setTransientKeyStatus("Please paste a valid API key.")
            return
        }
        do {
            try environment.keychainService.storeToken(key)
            environment.secureStorage.clearAuthenticationCache()
            hideRevealedKey()
            hasSavedKey = environment.keychainService.tokenExists()
            pastedKey = ""
            updateStatus()
        } catch {
            setTransientKeyStatus("Unable to save API key.")
        }
    }

    func removeKey() async {
        guard beginKeyAction(.removing) else { return }
        defer { endKeyAction(.removing) }

        guard hasSavedKey else {
            setTransientKeyStatus("No key available.")
            return
        }

        do {
            _ = try await environment.secureStorage.retrieveTokenRequiringAuthentication(
                reason: "Authenticate to remove your Shopmonkey API key.",
                preferCached: false
            )
        } catch let error as SecureStorage.SecureStorageError {
            switch error {
            case .userCancelled:
                setTransientKeyStatus("Authentication cancelled.")
            case .authenticationFailed, .biometricsUnavailable:
                setTransientKeyStatus("Authentication failed.")
            }
            return
        } catch {
            setTransientKeyStatus("Authentication failed.")
            return
        }

        do {
            try environment.keychainService.deleteToken()
            environment.secureStorage.clearAuthenticationCache()
            hideRevealedKey()
            hasSavedKey = environment.keychainService.tokenExists()
            updateStatus()
        } catch {
            setTransientKeyStatus("Unable to remove API key.")
        }
    }

    func retrieveKeyForUse() async -> String? {
        guard beginKeyAction(.verifying) else { return nil }
        defer { endKeyAction(.verifying) }

        guard hasSavedKey else {
            setTransientKeyStatus("No key available.")
            return nil
        }

        do {
            let token = try await environment.secureStorage.retrieveTokenRequiringAuthentication(
                reason: "Authenticate to access your Shopmonkey API key.",
                preferCached: false
            )
            setTransientKeyStatus("Stored key is available.")
            return token
        } catch let error as SecureStorage.SecureStorageError {
            switch error {
            case .userCancelled:
                setTransientKeyStatus("Authentication cancelled.")
            case .authenticationFailed, .biometricsUnavailable:
                setTransientKeyStatus("Authentication failed.")
            }
            return nil
        } catch {
            setTransientKeyStatus("Authentication failed.")
            return nil
        }
    }

    func authorizeForKeyEditorAccess() async -> Bool {
        guard hasSavedKey else { return true }
        guard beginKeyAction(.authorizingEdit) else { return false }
        defer { endKeyAction(.authorizingEdit) }

        do {
            _ = try await environment.secureStorage.retrieveTokenRequiringAuthentication(
                reason: "Authenticate to edit your Shopmonkey API key.",
                preferCached: false
            )
            return true
        } catch let error as SecureStorage.SecureStorageError {
            switch error {
            case .userCancelled:
                setTransientKeyStatus("Authentication cancelled.")
            case .authenticationFailed, .biometricsUnavailable:
                setTransientKeyStatus("Authentication failed.")
            }
            return false
        } catch {
            setTransientKeyStatus("Authentication failed.")
            return false
        }
    }

    func updateStatus() {
        hasSavedKey = environment.keychainService.tokenExists()
        if !hasSavedKey {
            hideRevealedKey()
        }
        keyStatusMessage = hasSavedKey ? "API key is saved in Keychain." : "No API key saved."
    }

    func revealStoredKey() async {
        guard beginKeyAction(.revealing) else { return }
        defer { endKeyAction(.revealing) }

        guard hasSavedKey else {
            setTransientKeyStatus("No key available.")
            return
        }

        do {
            let token = try await environment.secureStorage.retrieveTokenRequiringAuthentication(
                reason: "Authenticate to reveal your Shopmonkey API key.",
                preferCached: false
            )
            revealedAPIKey = token
            setTransientKeyStatus("Key revealed for 20 seconds.")
            scheduleRevealAutoHide(after: 20)
        } catch let error as SecureStorage.SecureStorageError {
            switch error {
            case .userCancelled:
                setTransientKeyStatus("Authentication cancelled.")
            case .authenticationFailed, .biometricsUnavailable:
                setTransientKeyStatus("Authentication failed.")
            }
        } catch {
            setTransientKeyStatus("Unable to reveal API key.")
        }
    }

    func hideRevealedKey() {
        keyRevealClearTask?.cancel()
        revealedAPIKey = nil
    }

    func copyStoredKey() async {
        guard beginKeyAction(.copying) else { return }
        defer { endKeyAction(.copying) }

        guard hasSavedKey else {
            setTransientKeyStatus("No key available.")
            return
        }

        do {
            let token = try await environment.secureStorage.retrieveTokenRequiringAuthentication(
                reason: "Authenticate to copy your Shopmonkey API key.",
                preferCached: false
            )
            #if canImport(UIKit)
            UIPasteboard.general.string = token
            setTransientKeyStatus("API key copied for 60 seconds.")
            scheduleClipboardAutoClear(expectedToken: token, after: 60)
            #else
            setTransientKeyStatus("Copy unavailable on this platform.")
            #endif
        } catch let error as SecureStorage.SecureStorageError {
            switch error {
            case .userCancelled:
                setTransientKeyStatus("Authentication cancelled.")
            case .authenticationFailed, .biometricsUnavailable:
                setTransientKeyStatus("Authentication failed.")
            }
        } catch {
            setTransientKeyStatus("Unable to copy API key.")
        }
    }

    @discardableResult
    func pasteAPIKeyFromClipboard() -> Bool {
        #if canImport(UIKit)
        let pastedValue = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pastedValue.isEmpty else {
            setTransientKeyStatus("Clipboard is empty.")
            return false
        }
        pastedKey = pastedValue
        return true
        #else
        setTransientKeyStatus("Clipboard is unavailable on this platform.")
        return false
        #endif
    }

    func testConnection() async {
        isTestingConnection = true
        connectivityStatusMessage = nil
        clearLastErrorDiagnostic()

        do {
            try storeTokenFromInputIfNeeded()
            try await authenticateForConnectivityAction(
                reason: "Authenticate to verify your Shopmonkey connection."
            )
            try await environment.shopmonkeyAPI.testConnection()
            connectivityStatusMessage = "Shopmonkey connection verified."
            clearLastErrorDiagnostic()
        } catch let error as SecureStorage.SecureStorageError {
            recordDiagnosticError(
                message: connectivityAuthMessage(for: error),
                code: .authChallengeFailed
            )
        } catch {
            recordDiagnosticError(error)
        }

        await refreshNetworkDiagnostics()
        await refreshFallbackAnalytics()
        isTestingConnection = false
    }

    func runEndpointProbe() async {
        isRunningProbe = true
        connectivityStatusMessage = nil
        endpointProbeReport = nil
        clearLastErrorDiagnostic()

        do {
            try storeTokenFromInputIfNeeded()
            try await authenticateForConnectivityAction(
                reason: "Authenticate to run Shopmonkey endpoint diagnostics."
            )
            let report = try await environment.shopmonkeyAPI.runEndpointProbe()
            endpointProbeReport = report

            if report.createPurchaseOrderLikelySupported {
                connectivityStatusMessage = "Probe complete: purchase-order routes are reachable."
            } else {
                connectivityStatusMessage = "Probe complete: purchase-order routes not fully confirmed."
            }
            clearLastErrorDiagnostic()
        } catch let error as SecureStorage.SecureStorageError {
            recordDiagnosticError(
                message: connectivityAuthMessage(for: error),
                code: .authChallengeFailed
            )
        } catch {
            recordDiagnosticError(error)
        }

        await refreshNetworkDiagnostics()
        await refreshFallbackAnalytics()
        isRunningProbe = false
    }

    func refreshNetworkDiagnostics() async {
        networkDiagnostics = await environment.networkDiagnostics.latest(limit: 120)
    }

    func clearNetworkDiagnostics() async {
        await environment.networkDiagnostics.clear()
        networkDiagnostics = []
        connectivityStatusMessage = "Network capture cleared."
    }

    func refreshFallbackAnalytics() async {
        let snapshot = await FallbackAnalyticsStore.shared.snapshot()
        fallbackAnalyticsTotalEvents = snapshot.totalEvents
        fallbackAnalyticsLastBranch = snapshot.lastUsedBranch
        fallbackAnalyticsLastTimestamp = snapshot.lastUsedTimestamp
        fallbackAnalyticsTopBranches = snapshot.topBranches(limit: 5).map { branch in
            FallbackBranchCount(branch: branch.branch, count: branch.count)
        }
    }

    func clearFallbackAnalytics() async {
        await FallbackAnalyticsStore.shared.clear()
        await refreshFallbackAnalytics()
    }

    func refreshTelemetrySummary() async {
        let summary = await environment.telemetryQueue.snapshotSummary()
        telemetryTotalEvents = summary.totalEvents
        telemetryLastEventTimestamp = summary.lastEventTimestamp
        telemetryTopEvents = summary.topEventCounts(limit: 5).map { entry in
            TelemetryEventCount(eventName: entry.eventName, count: entry.count)
        }
    }

    func setTelemetryEnabled(_ enabled: Bool, clearWhenDisabled: Bool) async {
        await environment.telemetryQueue.setEnabled(enabled, clearWhenDisabled: clearWhenDisabled)
        await refreshTelemetrySummary()
    }

    func clearTelemetryData() async {
        await environment.telemetryQueue.clear()
        await refreshTelemetrySummary()
        connectivityStatusMessage = "Telemetry data cleared."
    }

    func copyTelemetrySummary() async {
        let text = await environment.telemetryQueue.exportSummaryText(limit: 10)
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        connectivityStatusMessage = "Telemetry summary copied."
        #else
        connectivityStatusMessage = "Copy unavailable on this platform."
        #endif
    }

    func copyNetworkDiagnostics() async {
        let text = await environment.networkDiagnostics.exportText(limit: 200)
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        connectivityStatusMessage = "Network capture copied."
        #else
        connectivityStatusMessage = "Copy unavailable on this platform."
        #endif
    }

    func copyDiagnosticInfo() async {
        guard let diagnosticText = diagnosticSupportText() else {
            connectivityStatusMessage = "No diagnostic info available."
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = diagnosticText
        connectivityStatusMessage = "Diagnostic info copied."
        #else
        connectivityStatusMessage = "Copy unavailable on this platform."
        #endif
    }

    private func setTransientKeyStatus(_ message: String, autoClearAfter seconds: Double = 3.0) {
        keyStatusMessage = message
        keyStatusClearTask?.cancel()
        keyStatusClearTask = Task { [weak self] in
            let delayNanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            await MainActor.run {
                guard let self else { return }
                if self.keyStatusMessage == message {
                    self.keyStatusMessage = nil
                }
            }
        }
    }

    private func scheduleRevealAutoHide(after seconds: Double) {
        keyRevealClearTask?.cancel()
        keyRevealClearTask = Task { [weak self] in
            let delayNanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            await MainActor.run {
                self?.revealedAPIKey = nil
            }
        }
    }

    private func scheduleClipboardAutoClear(expectedToken: String, after seconds: Double) {
        clipboardClearTask?.cancel()
        clipboardClearTask = Task { [weak self] in
            let delayNanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            await MainActor.run {
                #if canImport(UIKit)
                guard UIPasteboard.general.string == expectedToken else { return }
                UIPasteboard.general.string = ""
                self?.setTransientKeyStatus("Clipboard key cleared.")
                #else
                _ = self
                #endif
            }
        }
    }

    private func beginKeyAction(_ action: KeyAction) -> Bool {
        guard activeKeyAction == nil else { return false }
        activeKeyAction = action
        return true
    }

    private func endKeyAction(_ action: KeyAction) {
        guard activeKeyAction == action else { return }
        activeKeyAction = nil
    }

    private func authenticateForConnectivityAction(reason: String) async throws {
        guard hasSavedKey else { return }
        _ = try await environment.secureStorage.retrieveTokenRequiringAuthentication(
            reason: reason,
            preferCached: false
        )
    }

    private func connectivityAuthMessage(for error: SecureStorage.SecureStorageError) -> String {
        switch error {
        case .userCancelled:
            return "Authentication cancelled."
        case .authenticationFailed, .biometricsUnavailable:
            return "Authentication failed."
        }
    }

    private func clearLastErrorDiagnostic() {
        lastErrorMessage = nil
        lastDiagnosticCode = nil
    }

    private func recordDiagnosticError(_ error: Error) {
        recordDiagnosticError(
            message: baseUserMessage(for: error),
            code: diagnosticCode(for: error)
        )
    }

    private func recordDiagnosticError(message: String, code: DiagnosticCode) {
        lastErrorMessage = message
        lastDiagnosticCode = code
        connectivityStatusMessage = formattedUserMessage(baseMessage: "Error: \(message)", code: code)
    }

    private func diagnosticSupportText() -> String? {
        guard let message = lastErrorMessage,
              let code = lastDiagnosticCode else {
            return nil
        }

        var components = [
            "Diagnostic ID: \(code.rawValue)",
            "Title: \(code.userFacingTitle)",
            "Message: \(message)"
        ]

        if let suggestedAction = code.suggestedAction, !suggestedAction.isEmpty {
            components.append("Suggested Action: \(suggestedAction)")
        }

        return components.joined(separator: "\n")
    }
}
