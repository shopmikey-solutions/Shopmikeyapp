//
//  DiagnosticsExportView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync

struct DiagnosticsExportView: View {
    @StateObject private var viewModel: DiagnosticsExportViewModel

    init(
        syncOperationQueue: SyncOperationQueueStore,
        networkDiagnostics: NetworkDiagnosticsRecorder,
        authConfigured: @escaping () -> Bool,
        shopmonkeyBaseURL: URL
    ) {
        _viewModel = StateObject(
            wrappedValue: DiagnosticsExportViewModel(
                syncOperationQueue: syncOperationQueue,
                networkDiagnostics: networkDiagnostics,
                authConfigured: authConfigured,
                shopmonkeyBaseURL: shopmonkeyBaseURL
            )
        )
    }

    var body: some View {
        List {
            Section {
                Text("Contains non-personal diagnostic info (queue status, sync health, app version). No payloads/customer data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await viewModel.generateDiagnosticsFile() }
                } label: {
                    if viewModel.isGenerating {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Generating…")
                        }
                    } else {
                        Text("Generate Diagnostics File")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isGenerating)
                .accessibilityIdentifier("exportDiagnostics.generateButton")
            }

            if let fileName = viewModel.generatedFileName {
                Section("Generated File") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(fileName)
                            .font(.callout.monospaced())
                            .accessibilityIdentifier("exportDiagnostics.fileNameLabel")

                        if let generatedAt = viewModel.generatedAt {
                            Text("Generated at \(generatedAt)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let fileURL = viewModel.generatedFileURL {
                        ShareLink(item: fileURL) {
                            Label("Share Diagnostics File", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("exportDiagnostics.shareLink")
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .accessibilityIdentifier("exportDiagnostics.errorLabel")
                }
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("Export Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
