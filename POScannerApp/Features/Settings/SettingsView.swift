//
//  SettingsView.swift
//  POScannerApp
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("saveHistoryEnabled") private var saveHistoryEnabled: Bool = true
    @AppStorage("scanLiveActivitiesEnabled") private var scanLiveActivitiesEnabled: Bool = true
    @AppStorage("scanWidgetRefreshEnabled") private var scanWidgetRefreshEnabled: Bool = true
    @AppStorage(LocalNotificationService.enabledKey) private var scanLocalNotificationsEnabled: Bool = true
    @StateObject private var viewModel: SettingsViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(environment: environment))
    }

    var body: some View {
        List {
            Section("Shopmonkey Connectivity") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        healthChip(title: "\(viewModel.networkDiagnostics.count) captured calls", color: AppSurfaceStyle.info)
                        healthChip(title: "\(failureDiagnosticsCount) failures", color: failureDiagnosticsCount > 0 ? .red : AppSurfaceStyle.success)
                    }

                    if let statusMessage = viewModel.statusMessage, !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use Test Connection or Endpoint Probe to confirm Shopmonkey routing before parts intake.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Parts Intake Preferences") {
                Toggle("Save History", isOn: $saveHistoryEnabled)
                    .accessibilityIdentifier("settings.saveHistoryToggle")
                Toggle("Ignore Tax & Totals", isOn: $viewModel.ignoreTaxAndTotals)
                    .accessibilityIdentifier("settings.ignoreTaxToggle")
                Toggle("Live Activities", isOn: $scanLiveActivitiesEnabled)
                    .accessibilityIdentifier("settings.liveActivitiesToggle")
                Toggle("Widget Refresh", isOn: $scanWidgetRefreshEnabled)
                    .accessibilityIdentifier("settings.widgetRefreshToggle")
                Toggle("Local Notifications", isOn: $scanLocalNotificationsEnabled)
                    .accessibilityIdentifier("settings.localNotificationsToggle")

                Text("Live Activities show active intake progress on the Lock Screen and Dynamic Island. Widget refresh publishes the latest dashboard snapshot for widgets. Local notifications alert you when scans are ready or submissions fail.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Shopmonkey API") {
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
                    AppHaptics.impact(.medium, intensity: 0.85)
                    Task { await viewModel.testConnection() }
                } label: {
                    if viewModel.isTestingConnection {
                        Label("Testing…", systemImage: "hourglass")
                    } else {
                        Text("Test Connection")
                    }
                }
                .appPrimaryActionButton()
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
                Toggle("Experimental Order / PO Linking", isOn: $viewModel.experimentalOrderPOLinking)
                    .accessibilityIdentifier("settings.experimentalLinkingToggle")

                Text("Shows advanced add-to-order and add-to-PO flows during parts intake review.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                NavigationLink("Endpoint Probe & Network Capture") {
                    SettingsDiagnosticsView(viewModel: viewModel)
                }
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .keyboardDoneToolbar()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Shopmonkey Settings")
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: saveHistoryEnabled) { _, _ in
            AppHaptics.selection()
        }
        .onChange(of: viewModel.ignoreTaxAndTotals) { _, _ in
            AppHaptics.selection()
        }
        .onChange(of: scanLiveActivitiesEnabled) { _, enabled in
            AppHaptics.selection()
            guard !enabled else { return }
            PartsIntakeLiveActivityBridge.sync(
                isActive: false,
                statusText: "",
                detailText: "",
                progress: 0
            )
        }
        .onChange(of: scanWidgetRefreshEnabled) { _, _ in
            AppHaptics.selection()
        }
        .onChange(of: scanLocalNotificationsEnabled) { _, enabled in
            AppHaptics.selection()
            guard enabled else { return }
            Task {
                _ = await viewModel.environment.localNotificationService.requestAuthorizationIfNeeded()
            }
        }
        .onChange(of: viewModel.experimentalOrderPOLinking) { _, _ in
            AppHaptics.selection()
        }
        .onChange(of: viewModel.statusMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            let lower = message.lowercased()
            if lower.contains("fail") || lower.contains("error") || lower.contains("unable") {
                AppHaptics.error()
            } else {
                AppHaptics.success()
            }
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
                    AppHaptics.impact(.medium, intensity: 0.8)
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
                                    .foregroundStyle(result.supported ? AppSurfaceStyle.success : AppSurfaceStyle.warning)
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
                ControlGroup {
                    Button("Refresh") {
                        AppHaptics.selection()
                        Task { await viewModel.refreshNetworkDiagnostics() }
                    }

                    Button("Copy") {
                        AppHaptics.selection()
                        Task { await viewModel.copyNetworkDiagnostics() }
                    }

                    Button("Clear", role: .destructive) {
                        AppHaptics.warning()
                        Task { await viewModel.clearNetworkDiagnostics() }
                    }
                }
                .controlSize(.small)

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
                                    .foregroundStyle(entry.isFailure ? .red : AppSurfaceStyle.success)
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
