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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            fallbackAnalyticsSection
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .keyboardDoneToolbar()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.refreshFallbackAnalytics()
        }
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
            keyStatusRow

            if showsAPIKeyEditor || !viewModel.hasSavedKey {
                apiKeyEditor
            }

            if viewModel.hasSavedKey {
                savedKeyActions
            }

            if let keyActionActivityText {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(keyActionActivityText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.keyActionProgress")
            }

            if let revealedAPIKey = viewModel.revealedAPIKey, !revealedAPIKey.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revealed temporarily (auto-hides)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(revealedAPIKey)
                        .font(.caption.monospaced())
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
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Key edit/view actions always require authentication. Enable the toggle to also require authentication before submission.")
        }
    }

    private var keyStatusRow: some View {
        LabeledContent {
            Text(viewModel.hasSavedKey ? "Saved in Keychain" : "Missing")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(viewModel.hasSavedKey ? AppSurfaceStyle.success : .secondary)
        } label: {
            Label("Status", systemImage: viewModel.hasSavedKey ? "checkmark.seal.fill" : "key")
                .foregroundStyle(viewModel.hasSavedKey ? AppSurfaceStyle.success : .secondary)
        }
    }

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Paste API Key", text: $viewModel.pastedKey, axis: .vertical)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...4)
                .accessibilityIdentifier("settings.apiKeyField")

            Button {
                self.pasteAPIKeyFromClipboard()
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.activeKeyAction != nil)
            .accessibilityIdentifier("settings.pasteApiKeyButton")

            if shouldStackAPIKeyEditorActions {
                VStack(alignment: .leading, spacing: 8) {
                    saveAPIKeyButton
                    if viewModel.hasSavedKey {
                        cancelEditingAPIKeyButton
                    }
                }
            } else {
                HStack(spacing: 12) {
                    saveAPIKeyButton
                    if viewModel.hasSavedKey {
                        cancelEditingAPIKeyButton
                    }
                }
            }
        }
    }

    private var savedKeyActions: some View {
        Group {
            Button {
                AppHaptics.impact(.medium, intensity: 0.85)
                Task { _ = await viewModel.retrieveKeyForUse() }
            } label: {
                if viewModel.activeKeyAction == .verifying {
                    Label("Verifying Key Access…", systemImage: "hourglass")
                } else {
                    Label("Verify Stored Key", systemImage: "checkmark.shield")
                }
            }
            .accessibilityIdentifier("settings.testRetrievalButton")
            .disabled(viewModel.activeKeyAction != nil)

            Button {
                AppHaptics.selection()
                if showsAPIKeyEditor {
                    showsAPIKeyEditor = false
                    viewModel.pastedKey = ""
                } else {
                    Task {
                        let authorized = await viewModel.authorizeForKeyEditorAccess()
                        guard authorized else { return }
                        await MainActor.run {
                            showsAPIKeyEditor = true
                        }
                    }
                }
            } label: {
                Label(showsAPIKeyEditor ? "Hide API Key Editor" : "Edit API Key", systemImage: "pencil")
            }
            .disabled(viewModel.activeKeyAction != nil)

            NavigationLink {
                SettingsAPIKeyActionsView(
                    viewModel: viewModel,
                    onRemoveKey: {
                        showsAPIKeyEditor = false
                    }
                )
            } label: {
                Label("Advanced Key Actions", systemImage: "key.horizontal")
            }
            .accessibilityIdentifier("settings.apiKeyActionsMenu")
            .disabled(viewModel.activeKeyAction != nil)
        }
    }

    private var saveAPIKeyButton: some View {
        Button("Save") {
            AppHaptics.selection()
            viewModel.saveKey()
            showsAPIKeyEditor = false
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.saveApiKeyButton")
        .disabled(viewModel.activeKeyAction != nil)
    }

    private var cancelEditingAPIKeyButton: some View {
        Button("Cancel") {
            AppHaptics.selection()
            showsAPIKeyEditor = false
            viewModel.pastedKey = ""
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.activeKeyAction != nil)
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
                    Label("Testing Connection…", systemImage: "hourglass")
                } else {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }
            }
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

    private var fallbackAnalyticsSection: some View {
        Section("Fallback Analytics") {
            LabeledContent("Total events") {
                Text("\(viewModel.fallbackAnalyticsTotalEvents)")
                    .font(.subheadline.monospacedDigit())
            }

            LabeledContent("Last branch") {
                if let lastBranch = viewModel.fallbackAnalyticsLastBranch, !lastBranch.isEmpty {
                    Text(lastBranch)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("n/a")
                        .foregroundStyle(.secondary)
                }
            }

            if let timestamp = viewModel.fallbackAnalyticsLastTimestamp {
                LabeledContent("Last updated") {
                    Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.fallbackAnalyticsTopBranches.isEmpty {
                Text("No fallback branches recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top branches")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.fallbackAnalyticsTopBranches) { branch in
                        HStack {
                            Text(branch.branch)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                            Spacer(minLength: 12)
                            Text("\(branch.count)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }

            Button("Clear Fallback Analytics", role: .destructive) {
                AppHaptics.selection()
                Task { await viewModel.clearFallbackAnalytics() }
            }
            .accessibilityIdentifier("settings.clearFallbackAnalyticsButton")
        }
    }

    private var failureDiagnosticsCount: Int {
        viewModel.networkDiagnostics.filter(\.isFailure).count
    }

    private var keyActionActivityText: String? {
        switch viewModel.activeKeyAction {
        case .saving:
            "Saving key…"
        case .authorizingEdit:
            "Authenticating to edit key…"
        case .verifying:
            "Verifying key access…"
        case .revealing:
            "Authenticating to reveal key…"
        case .copying:
            "Authenticating to copy key…"
        case .removing:
            "Removing key…"
        case nil:
            nil
        }
    }

    private var shouldStackAPIKeyEditorActions: Bool {
        dynamicTypeSize >= .accessibility1 || horizontalSizeClass == .compact
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

    private func pasteAPIKeyFromClipboard() {
        if self.viewModel.pasteAPIKeyFromClipboard() {
            AppHaptics.selection()
        } else {
            AppHaptics.warning()
        }
    }

}

private struct SettingsAPIKeyActionsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onRemoveKey: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Sensitive Actions") {
                Button {
                    AppHaptics.selection()
                    if viewModel.revealedAPIKey == nil {
                        Task { await viewModel.revealStoredKey() }
                    } else {
                        viewModel.hideRevealedKey()
                    }
                } label: {
                    if viewModel.activeKeyAction == .revealing {
                        Label("Authenticating…", systemImage: "hourglass")
                    } else {
                        Label(
                            viewModel.revealedAPIKey == nil ? "Reveal API Key" : "Hide Revealed Key",
                            systemImage: viewModel.revealedAPIKey == nil ? "eye" : "eye.slash"
                        )
                    }
                }
                .accessibilityIdentifier("settings.revealApiKeyButton")
                .disabled(viewModel.activeKeyAction != nil)

                Button {
                    AppHaptics.selection()
                    Task { await viewModel.copyStoredKey() }
                } label: {
                    if viewModel.activeKeyAction == .copying {
                        Label("Copying…", systemImage: "hourglass")
                    } else {
                        Label("Copy API Key", systemImage: "doc.on.doc")
                    }
                }
                .accessibilityIdentifier("settings.copyApiKeyButton")
                .disabled(viewModel.activeKeyAction != nil)
            }

            if let revealedAPIKey = viewModel.revealedAPIKey, !revealedAPIKey.isEmpty {
                Section {
                    Text(revealedAPIKey)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .truncationMode(.middle)
                } header: {
                    Text("Revealed Value")
                } footer: {
                    Text("This value automatically hides after a short delay.")
                }
            }

            Section {
                Button(role: .destructive) {
                    AppHaptics.warning()
                    Task {
                        await viewModel.removeKey()
                        if !viewModel.hasSavedKey {
                            onRemoveKey()
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.activeKeyAction == .removing {
                        Label("Removing…", systemImage: "hourglass")
                    } else {
                        Label("Remove API Key", systemImage: "trash")
                    }
                }
                .accessibilityIdentifier("settings.removeApiKeyButton")
                .disabled(viewModel.activeKeyAction != nil)
            } footer: {
                Text("Removing the key immediately disables Shopmonkey submissions.")
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("API Key Actions")
        .navigationBarTitleDisplayMode(.inline)
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
