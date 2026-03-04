//
//  DiagnosticsExportViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync

@MainActor
final class DiagnosticsExportViewModel: ObservableObject {
    @Published private(set) var isGenerating = false
    @Published private(set) var generatedFileURL: URL?
    @Published private(set) var generatedFileName: String?
    @Published private(set) var generatedAt: String?
    @Published private(set) var errorMessage: String?

    private let fetchOperations: @Sendable () async -> [SyncOperation]
    private let fetchNetworkFailures: @Sendable () async -> [NetworkDiagnosticsEntry]
    private let authConfigured: () -> Bool
    private let shopmonkeyBaseURL: URL
    private let bundleBuilder: DiagnosticsSupportBundleBuilder

    init(
        syncOperationQueue: SyncOperationQueueStore,
        networkDiagnostics: NetworkDiagnosticsRecorder,
        authConfigured: @escaping () -> Bool,
        shopmonkeyBaseURL: URL,
        bundleBuilder: DiagnosticsSupportBundleBuilder = DiagnosticsSupportBundleBuilder()
    ) {
        self.fetchOperations = { await syncOperationQueue.allOperations() }
        self.fetchNetworkFailures = { await networkDiagnostics.latest() }
        self.authConfigured = authConfigured
        self.shopmonkeyBaseURL = shopmonkeyBaseURL
        self.bundleBuilder = bundleBuilder
    }

    init(
        fetchOperations: @escaping @Sendable () async -> [SyncOperation],
        fetchNetworkFailures: @escaping @Sendable () async -> [NetworkDiagnosticsEntry],
        authConfigured: @escaping () -> Bool,
        shopmonkeyBaseURL: URL,
        bundleBuilder: DiagnosticsSupportBundleBuilder
    ) {
        self.fetchOperations = fetchOperations
        self.fetchNetworkFailures = fetchNetworkFailures
        self.authConfigured = authConfigured
        self.shopmonkeyBaseURL = shopmonkeyBaseURL
        self.bundleBuilder = bundleBuilder
    }

    func generateDiagnosticsFile() async {
        isGenerating = true
        errorMessage = nil

        let operations = await fetchOperations()
        let failures = await fetchNetworkFailures()

        do {
            let result = try bundleBuilder.buildAndWrite(
                from: operations,
                shopmonkeyBaseURL: shopmonkeyBaseURL,
                authConfigured: authConfigured(),
                networkFailures: failures
            )
            generatedFileURL = result.fileURL
            generatedFileName = result.fileURL.lastPathComponent
            generatedAt = result.bundle.generatedAt
        } catch {
            generatedFileURL = nil
            generatedFileName = nil
            generatedAt = nil
            errorMessage = "Unable to generate diagnostics file."
        }

        isGenerating = false
    }
}
