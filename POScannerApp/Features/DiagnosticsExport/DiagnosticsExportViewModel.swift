//
//  DiagnosticsExportViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import ShopmikeyCoreSync

@MainActor
final class DiagnosticsExportViewModel: ObservableObject {
    @Published private(set) var isGenerating = false
    @Published private(set) var generatedFileURL: URL?
    @Published private(set) var generatedFileName: String?
    @Published private(set) var generatedAt: String?
    @Published private(set) var errorMessage: String?

    private let fetchOperations: @Sendable () async -> [SyncOperation]
    private let bundleBuilder: DiagnosticsSupportBundleBuilder

    init(
        syncOperationQueue: SyncOperationQueueStore,
        bundleBuilder: DiagnosticsSupportBundleBuilder = DiagnosticsSupportBundleBuilder()
    ) {
        self.fetchOperations = { await syncOperationQueue.allOperations() }
        self.bundleBuilder = bundleBuilder
    }

    init(
        fetchOperations: @escaping @Sendable () async -> [SyncOperation],
        bundleBuilder: DiagnosticsSupportBundleBuilder
    ) {
        self.fetchOperations = fetchOperations
        self.bundleBuilder = bundleBuilder
    }

    func generateDiagnosticsFile() async {
        isGenerating = true
        errorMessage = nil

        let operations = await fetchOperations()

        do {
            let result = try bundleBuilder.buildAndWrite(from: operations)
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
