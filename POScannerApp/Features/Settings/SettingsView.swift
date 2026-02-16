//
//  SettingsView.swift
//  POScannerApp
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("saveHistoryEnabled") private var saveHistoryEnabled: Bool = true
    @StateObject private var viewModel: SettingsViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(environment: environment))
    }

    var body: some View {
        Form {
            Section("Preferences") {
                Toggle("Save History", isOn: $saveHistoryEnabled)
                Toggle("Ignore Tax & Totals", isOn: $viewModel.ignoreTaxAndTotals)
            }

            Section("Shopmonkey Sandbox") {
                SecureField("API Key", text: $viewModel.apiKeyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    if viewModel.isTestingConnection {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Testing…")
                        }
                    } else {
                        Text("Test Connection")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isTestingConnection)

                Text("Stored securely in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Endpoint Probe") {
                Button {
                    Task { await viewModel.runEndpointProbe() }
                } label: {
                    if viewModel.isRunningProbe {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Probing...")
                        }
                    } else {
                        Text("Run Blind Endpoint Probe")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRunningProbe)

                if let report = viewModel.endpointProbeReport {
                    Text("Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(report.results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(result.method.rawValue) \(result.endpoint)")
                                    .font(.footnote.monospaced())
                                Spacer()
                                Text(result.statusCode.map(String.init) ?? "n/a")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(result.supported ? .green : .orange)
                            }
                            Text(result.hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let preview = result.responsePreview, !preview.isEmpty {
                                Text(preview)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Network Capture") {
                HStack {
                    Button("Refresh") {
                        Task { await viewModel.refreshNetworkDiagnostics() }
                    }
                    .buttonStyle(.bordered)

                    Button("Copy") {
                        Task { await viewModel.copyNetworkDiagnostics() }
                    }
                    .buttonStyle(.bordered)

                    Button("Clear", role: .destructive) {
                        Task { await viewModel.clearNetworkDiagnostics() }
                    }
                    .buttonStyle(.bordered)
                }

                if viewModel.networkDiagnostics.isEmpty {
                    Text("No captured calls yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.networkDiagnostics) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.statusCode.map(String.init) ?? "n/a")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(entry.isFailure ? .red : .green)
                            }

                            Text("\(entry.method) \(entry.url)")
                                .font(.caption.monospaced())
                                .lineLimit(1)

                            if let errorSummary = entry.errorSummary, !errorSummary.isEmpty {
                                Text(errorSummary)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            if let responseBodyPreview = entry.responseBodyPreview, !responseBodyPreview.isEmpty {
                                Text(responseBodyPreview)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            await viewModel.refreshNetworkDiagnostics()
        }
    }
}
