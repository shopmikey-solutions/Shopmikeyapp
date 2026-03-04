//
//  DiagnosticsCenterView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreNetworking

struct DiagnosticsCenterView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        List {
            connectionSection
            syncSection
            supportSection
            #if DEBUG
            advancedSection
            #endif
        }
        .accessibilityIdentifier("diagnosticsCenter.list")
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.refreshSyncHealth()
            await viewModel.refreshFallbackAnalytics()
            await viewModel.setTelemetryEnabled(viewModel.isTelemetryEnabled, clearWhenDisabled: false)
            await viewModel.refreshTelemetrySummary()
        }
        .onChange(of: viewModel.experimentalOrderPOLinking) { _, _ in
            AppHaptics.selection()
        }
        .onChange(of: viewModel.isTelemetryEnabled) { _, enabled in
            AppHaptics.selection()
            Task {
                await viewModel.setTelemetryEnabled(enabled, clearWhenDisabled: !enabled)
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
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
            .accessibilityIdentifier("diagnosticsCenter.testConnection")

            NavigationLink {
                SettingsDiagnosticsView(viewModel: viewModel)
            } label: {
                Label("Connection Diagnostics", systemImage: "network")
            }
            .accessibilityIdentifier("diagnosticsCenter.connectionDiagnostics")

            if let formattedLastErrorMessage = viewModel.formattedLastErrorMessage, !formattedLastErrorMessage.isEmpty {
                Text(formattedLastErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)

                Button {
                    AppHaptics.selection()
                    Task { await viewModel.copyDiagnosticInfo() }
                } label: {
                    Label("Copy Diagnostic Info", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("diagnosticsCenter.copyDiagnosticInfo")
            } else if let connectivityStatusMessage = viewModel.connectivityStatusMessage, !connectivityStatusMessage.isEmpty {
                Text(connectivityStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncSection: some View {
        Section("Sync Status") {
            HStack(spacing: 8) {
                healthChip(title: "Pending \(viewModel.pendingOperationCount)", color: AppSurfaceStyle.info)
                healthChip(title: "In Progress \(viewModel.inProgressOperationCount)", color: .blue)
                healthChip(title: "Failed \(viewModel.failedOperationCount)", color: viewModel.failedOperationCount > 0 ? .red : AppSurfaceStyle.success)
            }

            LabeledContent("Pending") {
                Text("\(viewModel.pendingOperationCount)")
                    .font(.subheadline.monospacedDigit())
            }

            LabeledContent("In Progress") {
                Text("\(viewModel.inProgressOperationCount)")
                    .font(.subheadline.monospacedDigit())
            }

            LabeledContent("Failed") {
                Text("\(viewModel.failedOperationCount)")
                    .font(.subheadline.monospacedDigit())
            }

            LabeledContent("Next Attempt") {
                if let nextAttempt = viewModel.nextScheduledAttempt {
                    Text(nextAttempt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("None")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Retry Failed Updates") {
                AppHaptics.selection()
                Task { await viewModel.retryFailedNow() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Retry failed sync updates")

            Button("Clear Failed Updates", role: .destructive) {
                AppHaptics.selection()
                Task { await viewModel.clearFailedOperations() }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Clear failed sync updates")
        }
    }

    private var supportSection: some View {
        Section("Support") {
            NavigationLink {
                SubmissionHealthView(syncOperationQueue: viewModel.environment.syncOperationQueue)
            } label: {
                Label("Sync Queue Details", systemImage: "waveform.path.ecg")
            }
            .accessibilityIdentifier("diagnosticsCenter.syncQueue")

            NavigationLink {
                DiagnosticsExportView(
                    syncOperationQueue: viewModel.environment.syncOperationQueue,
                    networkDiagnostics: viewModel.environment.networkDiagnostics,
                    authConfigured: { viewModel.environment.keychainService.tokenExists() },
                    shopmonkeyBaseURL: ShopmonkeyBaseURL.sandbox
                )
            } label: {
                Label("Share Diagnostics", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("diagnosticsCenter.shareDiagnostics")
        }
    }

    #if DEBUG
    private var advancedSection: some View {
        Section("Advanced") {
            Toggle("Experimental Ticket and PO Linking", isOn: $viewModel.experimentalOrderPOLinking)
                .accessibilityIdentifier("diagnosticsCenter.experimentalLinkingToggle")

            Text("Advanced tooling for support and development workflows.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            fallbackAnalyticsContent
            telemetryContent
        }
    }

    private var fallbackAnalyticsContent: some View {
        Group {
            LabeledContent("Fallback Events") {
                Text("\(viewModel.fallbackAnalyticsTotalEvents)")
                    .font(.subheadline.monospacedDigit())
            }

            LabeledContent("Last Fallback Branch") {
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
                LabeledContent("Last Updated") {
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
                    Text("Top Branches")
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
            .accessibilityIdentifier("diagnosticsCenter.clearFallbackAnalyticsButton")
        }
    }

    private var telemetryContent: some View {
        Group {
            Toggle("Share Diagnostics Telemetry", isOn: $viewModel.isTelemetryEnabled)
                .accessibilityIdentifier("diagnosticsCenter.telemetryToggle")

            Text("Off by default. Only redacted diagnostics metadata is stored locally.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if viewModel.isTelemetryEnabled {
                LabeledContent("Telemetry Events") {
                    Text("\(viewModel.telemetryTotalEvents)")
                        .font(.subheadline.monospacedDigit())
                }

                if let timestamp = viewModel.telemetryLastEventTimestamp {
                    LabeledContent("Last Event") {
                        Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.telemetryTopEvents.isEmpty {
                    Text("No telemetry events queued.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Events")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(viewModel.telemetryTopEvents) { event in
                            HStack {
                                Text(event.eventName)
                                    .font(.caption.monospaced())
                                Spacer(minLength: 12)
                                Text("\(event.count)")
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }

                Button("Copy Telemetry Summary") {
                    AppHaptics.selection()
                    Task { await viewModel.copyTelemetrySummary() }
                }
                .accessibilityIdentifier("diagnosticsCenter.copyTelemetrySummaryButton")

                Button("Clear Telemetry Data", role: .destructive) {
                    AppHaptics.selection()
                    Task { await viewModel.clearTelemetryData() }
                }
                .accessibilityIdentifier("diagnosticsCenter.clearTelemetryButton")
            }
        }
    }
    #endif

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

#if DEBUG
#Preview("Diagnostics Center") {
    NavigationStack {
        DiagnosticsCenterView(viewModel: SettingsViewModel(environment: PreviewFixtures.makeEnvironment(seedHistory: true)))
    }
}
#endif
