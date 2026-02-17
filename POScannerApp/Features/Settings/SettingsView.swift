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
        List {
            Section("Workspace Health") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        healthChip(title: "\(viewModel.networkDiagnostics.count) captured calls", color: .blue)
                        healthChip(title: "\(failureDiagnosticsCount) failures", color: failureDiagnosticsCount > 0 ? .red : .green)
                    }

                    if let statusMessage = viewModel.statusMessage, !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use Test Connection or the endpoint probe to validate API readiness.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Preferences") {
                Toggle("Save History", isOn: $saveHistoryEnabled)
                    .accessibilityIdentifier("settings.saveHistoryToggle")
                Toggle("Ignore Tax & Totals", isOn: $viewModel.ignoreTaxAndTotals)
                    .accessibilityIdentifier("settings.ignoreTaxToggle")
            }

            Section("Shopmonkey Sandbox") {
                SecureField("API Key", text: $viewModel.apiKeyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("settings.apiKeyField")

                if #available(iOS 16.0, *) {
                    PasteButton(payloadType: String.self) { values in
                        guard let first = values.first else { return }
                        viewModel.apiKeyInput = first
                    }
                }

                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    if viewModel.isTestingConnection {
                        Label("Testing…", systemImage: "hourglass")
                    } else {
                        Text("Test Connection")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isTestingConnection)
                .accessibilityIdentifier("settings.testConnectionButton")

                Text("Stored securely in Keychain")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                NavigationLink("Endpoint Probe & Network Capture") {
                    SettingsDiagnosticsView(viewModel: viewModel)
                }
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.refreshNetworkDiagnostics()
        }
    }

    private var failureDiagnosticsCount: Int {
        viewModel.networkDiagnostics.filter(\.isFailure).count
    }

    private func healthChip(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

private struct SettingsDiagnosticsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showOnlyFailedCalls: Bool = false

    var body: some View {
        List {
            Section("Endpoint Probe") {
                Button {
                    Task { await viewModel.runEndpointProbe() }
                } label: {
                    if viewModel.isRunningProbe {
                        Label("Probing…", systemImage: "hourglass")
                    } else {
                        Text("Run Blind Endpoint Probe")
                    }
                }
                .disabled(viewModel.isRunningProbe)

                if let report = viewModel.endpointProbeReport {
                    Text("Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
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
                                    .font(.caption.monospaced())
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Show only failures", isOn: $showOnlyFailedCalls)

                    ForEach(filteredDiagnostics) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospaced())
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
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if filteredDiagnostics.isEmpty {
                        Text("No calls match this filter.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.refreshNetworkDiagnostics()
        }
    }

    private var filteredDiagnostics: [NetworkDiagnosticsEntry] {
        if showOnlyFailedCalls {
            return viewModel.networkDiagnostics.filter(\.isFailure)
        }
        return viewModel.networkDiagnostics
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        SettingsView(environment: PreviewFixtures.makeEnvironment(seedHistory: true))
    }
}
#endif
