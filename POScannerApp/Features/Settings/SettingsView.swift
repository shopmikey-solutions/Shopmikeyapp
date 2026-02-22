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
    @State private var showsAPIKeyEditor: Bool = false

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(environment: environment))
    }

    var body: some View {
        List {
            apiKeySection
            connectivityChecksSection
            partsIntakePreferencesSection
            appExperienceSection
            diagnosticsSection
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .keyboardDoneToolbar()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
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
        .onChange(of: viewModel.connectivityStatusMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            let lower = message.lowercased()
            if lower.contains("fail") || lower.contains("error") || lower.contains("unable") {
                AppHaptics.error()
            } else {
                AppHaptics.success()
            }
        }
        .onChange(of: viewModel.keyStatusMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            let lower = message.lowercased()
            if lower.contains("unable") || lower.contains("no key") {
                AppHaptics.warning()
            } else {
                AppHaptics.selection()
            }
        }
    }

    private var apiKeySection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: viewModel.hasSavedKey ? "checkmark.seal.fill" : "key")
                    .foregroundStyle(viewModel.hasSavedKey ? AppSurfaceStyle.success : .secondary)
                Text("Status")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.hasSavedKey ? "Saved" : "Missing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.hasSavedKey ? AppSurfaceStyle.success : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((viewModel.hasSavedKey ? AppSurfaceStyle.success : .secondary).opacity(0.12))
                    .clipShape(Capsule())
            }

            if showsAPIKeyEditor || !viewModel.hasSavedKey {
                TextField("Paste API Key", text: $viewModel.pastedKey, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...4)
                    .accessibilityIdentifier("settings.apiKeyField")

                if #available(iOS 16.0, *) {
                    PasteButton(payloadType: String.self) { values in
                        guard let first = values.first else { return }
                        viewModel.pastedKey = first
                    }
                }

                HStack {
                    Button("Save") {
                        AppHaptics.selection()
                        viewModel.saveKey()
                        showsAPIKeyEditor = false
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.saveApiKeyButton")

                    if viewModel.hasSavedKey {
                        Button("Cancel") {
                            AppHaptics.selection()
                            showsAPIKeyEditor = false
                            viewModel.pastedKey = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                if viewModel.hasSavedKey {
                    Button {
                        AppHaptics.impact(.medium, intensity: 0.85)
                        Task { _ = await viewModel.retrieveKeyForUse() }
                    } label: {
                        Text("Verify")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.testRetrievalButton")

                    Button(showsAPIKeyEditor ? "Hide Editor" : "Edit Key") {
                        AppHaptics.selection()
                        showsAPIKeyEditor.toggle()
                    }
                    .buttonStyle(.bordered)

                    Button(viewModel.revealedAPIKey == nil ? "Reveal" : "Hide") {
                        AppHaptics.selection()
                        if viewModel.revealedAPIKey == nil {
                            Task { await viewModel.revealStoredKey() }
                        } else {
                            viewModel.hideRevealedKey()
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.revealApiKeyButton")

                    Button("Copy") {
                        AppHaptics.selection()
                        Task { await viewModel.copyStoredKey() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.copyApiKeyButton")
                }

                Spacer(minLength: 8)

                if viewModel.hasSavedKey {
                    Button("Remove", role: .destructive) {
                        AppHaptics.warning()
                        viewModel.removeKey()
                        showsAPIKeyEditor = false
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.removeApiKeyButton")
                }
            }

            if let revealedAPIKey = viewModel.revealedAPIKey, !revealedAPIKey.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revealed temporarily")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(revealedAPIKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                .padding(8)
                .background(AppSurfaceStyle.info.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Toggle("Require Face ID / Touch ID before submission", isOn: $viewModel.isBiometricRequired)
                .disabled(!viewModel.hasSavedKey)
                .accessibilityIdentifier("settings.requireBiometricsToggle")

            if let keyStatusMessage = viewModel.keyStatusMessage, !keyStatusMessage.isEmpty {
                Text(keyStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Authentication applies to key verification and Shopmonkey submissions.")
        }
    }

    private var connectivityChecksSection: some View {
        Section("Connectivity Checks") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    healthChip(title: "\(viewModel.networkDiagnostics.count) captured calls", color: AppSurfaceStyle.info)
                    healthChip(title: "\(failureDiagnosticsCount) failures", color: failureDiagnosticsCount > 0 ? .red : AppSurfaceStyle.success)
                }

                Text("Use these checks before first submission or after key changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let connectivityStatusMessage = viewModel.connectivityStatusMessage, !connectivityStatusMessage.isEmpty {
                    Text(connectivityStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

            NavigationLink("Endpoint Probe & Network Capture") {
                SettingsDiagnosticsView(viewModel: viewModel)
            }
        }
    }

    private var partsIntakePreferencesSection: some View {
        Section("Parts Intake Preferences") {
            preferenceToggle(
                title: "Save submitted history",
                isOn: $saveHistoryEnabled,
                description: "Keep a local history of submitted purchase orders for dashboard totals and audits.",
                accessibilityIdentifier: "settings.saveHistoryToggle"
            )
            preferenceToggle(
                title: "Ignore tax and totals",
                isOn: $viewModel.ignoreTaxAndTotals,
                description: "Apply to new scans and submissions.",
                accessibilityIdentifier: "settings.ignoreTaxToggle"
            )
        }
    }

    private var appExperienceSection: some View {
        Section("App Experience") {
            preferenceToggle(
                title: "Live Activities",
                isOn: $scanLiveActivitiesEnabled,
                description: "Show current intake progress on the Lock Screen and Dynamic Island.",
                accessibilityIdentifier: "settings.liveActivitiesToggle"
            )
            preferenceToggle(
                title: "Home Screen widget refresh",
                isOn: $scanWidgetRefreshEnabled,
                description: "Publish dashboard snapshot updates to the widget extension.",
                accessibilityIdentifier: "settings.widgetRefreshToggle"
            )
            preferenceToggle(
                title: "Local notifications",
                isOn: $scanLocalNotificationsEnabled,
                description: "Send scan-ready and submission-result notifications.",
                accessibilityIdentifier: "settings.localNotificationsToggle"
            )
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Toggle("Experimental Order / PO Linking", isOn: $viewModel.experimentalOrderPOLinking)
                .accessibilityIdentifier("settings.experimentalLinkingToggle")

            Text("Shows advanced add-to-order and add-to-PO flows during parts intake review.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var failureDiagnosticsCount: Int {
        viewModel.networkDiagnostics.filter(\.isFailure).count
    }

    private func preferenceToggle(
        title: String,
        isOn: Binding<Bool>,
        description: String,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .accessibilityIdentifier(accessibilityIdentifier)
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
