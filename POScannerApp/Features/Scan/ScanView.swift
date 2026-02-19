//
//  ScanView.swift
//  POScannerApp
//

import SwiftUI
import VisionKit
import PhotosUI

struct ScanView: View {
    @AppStorage("ignoreTaxAndTotals") private var ignoreTaxAndTotals: Bool = false
    @State private var showScanner: Bool = false
    @State private var showSourceSheet: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingPhoto: Bool = false
    @State private var showProcessingDetails: Bool = true
    @State private var hasPerformedInitialLoad: Bool = false
    @State private var initialLoadTask: Task<Void, Never>?
    @StateObject private var viewModel: ScanViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: ScanViewModel(environment: environment))
    }

    var body: some View {
        scanList
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .refreshable {
            viewModel.loadTodayMetrics()
        }
        .sensoryFeedback(.selection, trigger: ignoreTaxAndTotals)
        .safeAreaPadding(.top, viewModel.isProcessing ? 116 : 0)
        .navigationTitle("ShopMikey")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarCaptureButton
            }
        }
        .sheet(isPresented: $showSourceSheet) {
            ScanSourceSheet(
                onScanWithCamera: { showScanner = true },
                onChooseFromPhotos: { showPhotoPicker = true }
            )
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images,
            preferredItemEncoding: .current
        )
        .sheet(isPresented: $showScanner) {
            if VNDocumentCameraViewController.isSupported {
                VisionDocumentScanner(
                    onScan: { image, orientation in
                        showScanner = false
                        viewModel.handleScannedImage(
                            image,
                            orientation: orientation,
                            ignoreTaxAndTotals: ignoreTaxAndTotals
                        )
                    },
                    onCancel: {
                        showScanner = false
                    }
                )
            } else {
                ContentUnavailableView(
                    "Scanner Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Invoice capture is not supported on this device.")
                )
                .padding()
            }
        }
        .sheet(item: $viewModel.ocrReviewDraft) { draft in
            NavigationStack {
                OCRReviewView(
                    draft: draft,
                    onCancel: {
                        viewModel.cancelOCRReview()
                    },
                    onContinue: { reviewedText, includeDetectedBarcodes in
                        viewModel.continueFromOCRReview(
                            editedText: reviewedText,
                            includeDetectedBarcodes: includeDetectedBarcodes
                        )
                    }
                )
            }
        }
        .navigationDestination(item: $viewModel.parsedInvoiceRoute) { route in
            ReviewView(
                environment: viewModel.environment,
                parsedInvoice: route.invoice,
                draftSnapshot: route.draftSnapshot
            )
        }
        .onAppear {
            if !hasPerformedInitialLoad {
                hasPerformedInitialLoad = true
                initialLoadTask?.cancel()
                initialLoadTask = Task { @MainActor in
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard hasPerformedInitialLoad else { return }
                    viewModel.loadInProgressDrafts()
                    viewModel.loadTodayMetrics()
                }
            }
        }
        .onDisappear {
            initialLoadTask?.cancel()
            initialLoadTask = nil
        }
        .onChange(of: viewModel.processingStage) { _, stage in
            guard stage != nil else { return }
            AppHaptics.selection()
            syncLiveActivity()
        }
        .onChange(of: viewModel.isProcessing) { _, _ in
            syncLiveActivity()
        }
        .onChange(of: viewModel.parsedInvoiceRoute) { _, route in
            guard route != nil else { return }
            AppHaptics.success()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard message != nil else { return }
            AppHaptics.error()
        }
        .sensoryFeedback(trigger: viewModel.isProcessing) { _, processing in
            processing ? .impact(weight: .medium, intensity: 0.8) : .selection
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .overlay(alignment: .top) {
            processingBanner
        }
        .onReceive(NotificationCenter.default.publisher(for: .appOpenScanComposer)) { _ in
            presentCaptureFlow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appResumeScanDraft)) { notification in
            guard let draftID = notification.object as? UUID else { return }
            guard !viewModel.isProcessing else { return }
            Task {
                let resumed = await viewModel.resumeDraft(id: draftID)
                if !resumed {
                    await MainActor.run {
                        presentCaptureSourcePicker()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDraftStoreDidChange)) { _ in
            viewModel.loadInProgressDrafts()
        }
        .animation(.snappy(duration: 0.22), value: viewModel.inProgressDrafts)
    }

    private var scanList: some View {
        List {
            currentSessionSection
            dashboardSection
            preferencesSection
            draftsSection
            recentPostsSection
            toolsSection
            uiTestSection
            errorSection
        }
    }

    @ViewBuilder
    private var currentSessionSection: some View {
        if let latestDraft = viewModel.latestDraft {
            Section("Current Intake Session") {
                currentIntakeSessionCard(latestDraft)
            }
        }
    }

    private var dashboardSection: some View {
        Section("Parts Intake Overview") {
            dashboardSummary
        }
    }

    private var preferencesSection: some View {
        Section("Intake Preferences") {
            Toggle("Ignore tax and totals", isOn: $ignoreTaxAndTotals)
                .accessibilityIdentifier("scan.ignoreTaxToggle")
            Text("Use this when supplier totals are noisy and line-item pricing is the source of truth.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var draftsSection: some View {
        Section("In-Progress Parts Intake") {
            if additionalDrafts.isEmpty {
                Text(viewModel.latestDraft == nil ? "No saved intake drafts." : "No additional saved intake drafts.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(additionalDrafts) { draft in
                    draftRow(draft)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                AppHaptics.warning()
                                viewModel.deleteDraft(draft)
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var recentPostsSection: some View {
        Section("Recent Purchase Order Posts") {
            if let recent = viewModel.mostRecentSummary {
                NavigationLink {
                    HistoryView(environment: viewModel.environment)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recent.vendor)
                            .font(.headline)
                        Text("\(recent.total) • \(recent.date)")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No recent purchase-order submissions yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolsSection: some View {
        Section("Shopmonkey Tools") {
            NavigationLink("Purchase Order History") {
                HistoryView(environment: viewModel.environment)
            }
            .accessibilityIdentifier("scan.quickHistory")

            NavigationLink("Intake Settings") {
                SettingsView(environment: viewModel.environment)
            }
            .accessibilityIdentifier("scan.quickSettings")
        }
    }

    @ViewBuilder
    private var uiTestSection: some View {
        if viewModel.uiTestReviewFixtureEnabled {
            Section {
                Button("Open Review Fixture") {
                    viewModel.openUITestReviewFixture()
                }
                .accessibilityIdentifier("scan.openReviewFixture")
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage = viewModel.errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var toolbarCaptureButton: some View {
        Button {
            presentCaptureFlow()
        } label: {
            Label(
                viewModel.latestDraft == nil ? "Scan Parts Invoice" : "New Capture",
                systemImage: "doc.viewfinder"
            )
        }
        .appPrimaryActionButton()
        .disabled(showScanner || viewModel.isProcessing || isImportingPhoto)
        .accessibilityIdentifier("scan.scanButton")
    }

    @ViewBuilder
    private func draftRow(_ draft: ReviewDraftSnapshot) -> some View {
        if draft.canResumeInReview {
            Button {
                AppHaptics.selection()
                viewModel.resumeDraft(draft)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.displayVendorName)
                        .font(.headline)
                    Text("\(draft.displaySecondaryLine) • Saved \(draft.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.displayVendorName)
                    .font(.headline)
                Text("\(draft.workflowState.statusLabel) • Start a new capture to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func presentCaptureFlow() {
        guard !showScanner, !viewModel.isProcessing, !isImportingPhoto else { return }
        AppHaptics.impact(.medium, intensity: 0.9)
        presentCaptureSourcePicker()
    }

    private func presentCaptureSourcePicker() {
        guard !showScanner, !viewModel.isProcessing, !isImportingPhoto else { return }
        showSourceSheet = true
    }

    private var additionalDrafts: [ReviewDraftSnapshot] {
        guard viewModel.inProgressDrafts.count > 1 else { return [] }
        return Array(viewModel.inProgressDrafts.dropFirst())
    }

    private func currentIntakeSessionCard(_ draft: ReviewDraftSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(draft.workflowState.statusLabel, systemImage: "clock.arrow.circlepath")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(workflowTint(for: draft.workflowState))

                Spacer()

                Text("Saved \(draft.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(draft.displayVendorName)
                .font(.headline)

            Text(draft.displaySecondaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: draft.workflowProgressEstimate)
                .progressViewStyle(.linear)
                .tint(workflowTint(for: draft.workflowState))
                .animation(.smooth(duration: 0.22), value: draft.workflowProgressEstimate)

            currentSessionActions(for: draft)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("scan.currentSessionCard")
    }

    @ViewBuilder
    private func currentSessionActions(for draft: ReviewDraftSnapshot) -> some View {
        let canResume = viewModel.canResumeOCRReview(draft) || draft.canResumeInReview

        VStack(spacing: 8) {
            if viewModel.canResumeOCRReview(draft) {
                Button {
                    AppHaptics.selection()
                    viewModel.resumeOCRReview(draft)
                } label: {
                    actionButtonLabel(title: "Review OCR Draft", systemImage: "text.viewfinder")
                }
                .appPrimaryActionButton()
                .frame(maxWidth: .infinity)
            } else if draft.canResumeInReview {
                Button {
                    AppHaptics.selection()
                    viewModel.resumeDraft(draft)
                } label: {
                    actionButtonLabel(title: "Resume Intake Review", systemImage: "arrow.clockwise.circle")
                }
                .appPrimaryActionButton()
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    AppHaptics.selection()
                    presentCaptureSourcePicker()
                } label: {
                    actionButtonLabel(title: "Start New Capture", systemImage: "camera.viewfinder")
                }
                .appPrimaryActionButton()
                .frame(maxWidth: .infinity)
            }

            if canResume {
                Button {
                    AppHaptics.selection()
                    presentCaptureSourcePicker()
                } label: {
                    actionButtonLabel(title: "Start New Capture")
                }
                .appSecondaryActionButton()
                .frame(maxWidth: .infinity)
            }

            Button(role: .destructive) {
                AppHaptics.warning()
                viewModel.deleteDraft(draft)
            } label: {
                Text(canResume ? "Remove Draft" : "Remove Previous Session")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            if !draft.canResumeInReview {
                Text("This session cannot be resumed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func actionButtonLabel(title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            }
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }

    private func workflowTint(for state: ReviewDraftSnapshot.WorkflowState) -> Color {
        switch state {
        case .failed:
            return AppSurfaceStyle.warning
        case .reviewReady, .reviewEdited:
            return AppSurfaceStyle.success
        case .scanning, .ocrReview, .parsing, .submitting:
            return AppSurfaceStyle.info
        }
    }

    @ViewBuilder
    private var processingBanner: some View {
        if viewModel.isProcessing {
            VStack(alignment: .leading, spacing: 8) {
                Text("Live Parts Intake Pipeline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScanProcessingWidget(
                    startedAt: viewModel.processingStartedAt ?? Date(),
                    statusText: viewModel.processingStatusText,
                    detailText: viewModel.processingDetailText,
                    progress: viewModel.processingProgressEstimate,
                    showsDetail: $showProcessingDetails
                )
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("scan.processingBanner")
            .zIndex(20)
        }
    }

    private var dashboardSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parts Intake Dashboard")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("scan.dashboardTitle")

            Text("Capture supplier invoices, classify parts and tires, and keep Shopmonkey purchase orders moving.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                metricCell(title: "Scans Today", value: "\(viewModel.todayCount)")
                metricCell(title: "POs Submitted", value: "\(viewModel.submittedCount)")
                metricCell(title: "Needs Retry", value: "\(viewModel.failedCount)")
            }

            ProgressView(value: pipelineProgress) {
                Text("Shopmonkey Sync Status")
                    .font(.subheadline.weight(.medium))
            } currentValueLabel: {
                Text("\(Int((pipelineProgress * 100).rounded()))%")
                    .font(.footnote.monospacedDigit())
                    .contentTransition(.numericText())
            }
            .animation(.smooth(duration: 0.28), value: pipelineProgress)

            LabeledContent("PO Value Today") {
                Text(viewModel.todayTotalFormatted)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Average PO") {
                Text(viewModel.todayAverageFormatted)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy(duration: 0.26), value: viewModel.todayCount)
        .animation(.snappy(duration: 0.26), value: viewModel.submittedCount)
        .animation(.snappy(duration: 0.26), value: viewModel.failedCount)
    }

    private func metricCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pipelineProgress: Double {
        guard viewModel.todayCount > 0 else { return 0 }
        return min(1, Double(viewModel.submittedCount) / Double(viewModel.todayCount))
    }

    private func syncLiveActivity() {
        let payload = liveActivityPayload()
        PartsIntakeLiveActivityBridge.sync(
            isActive: payload.isActive,
            statusText: payload.status,
            detailText: payload.detail,
            progress: payload.progress,
            deepLinkURL: payload.deepLinkURL
        )
    }

    private func liveActivityPayload() -> (
        isActive: Bool,
        status: String,
        detail: String,
        progress: Double,
        deepLinkURL: URL?
    ) {
        if viewModel.isProcessing {
            let activeDraftID = viewModel.latestDraft?.id
            return (
                true,
                viewModel.processingStatusText,
                viewModel.processingDetailText,
                viewModel.processingProgressEstimate,
                activeDraftID.map { AppDeepLink.scanURL(draftID: $0) } ?? AppDeepLink.scanURL(openComposer: true)
            )
        }

        guard let latestDraft = viewModel.latestDraft else {
            return (false, "", "", 0, nil)
        }

        guard latestDraft.workflowState == .submitting else {
            return (false, "", "", 0, nil)
        }

        return (
            true,
            "Submitting to Shopmonkey",
            latestDraft.displaySecondaryLine,
            latestDraft.workflowProgressEstimate,
            AppDeepLink.scanURL(draftID: latestDraft.id)
        )
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !isImportingPhoto else { return }
        isImportingPhoto = true
        defer {
            isImportingPhoto = false
            selectedPhotoItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                viewModel.errorMessage = "Could not load the selected photo."
                AppHaptics.error()
                return
            }

            viewModel.handleScannedImage(
                image,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
        } catch is CancellationError {
            return
        } catch {
            viewModel.errorMessage = "Could not load the selected photo."
            AppHaptics.error()
        }
    }
}

private struct ScanSourceSheet: View {
    let onScanWithCamera: () -> Void
    let onChooseFromPhotos: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Use camera for a new capture, or choose an existing invoice photo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Capture Source") {
                    Button {
                        AppHaptics.selection()
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            onScanWithCamera()
                        }
                    } label: {
                        Label("Scan with Camera", systemImage: "camera.viewfinder")
                    }

                    Button {
                        AppHaptics.selection()
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            onChooseFromPhotos()
                        }
                    } label: {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                }

                Section {
                    Text("Camera uses live document scanning. Photos lets you import an existing invoice image.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Parts Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct ScanProcessingWidget: View {
    let startedAt: Date
    let statusText: String
    let detailText: String
    let progress: Double
    @Binding var showsDetail: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(AppSurfaceStyle.info)
                        .symbolEffect(.pulse.byLayer, options: .repeating, value: progress)
                    Text(statusText)
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text(elapsedString(elapsed))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if showsDetail {
                    ProgressView(value: max(0.02, min(1, progress)))
                        .progressViewStyle(.linear)
                        .tint(AppSurfaceStyle.info)

                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                AppHaptics.selection()
                withAnimation(.snappy(duration: 0.24)) {
                    showsDetail.toggle()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Double-tap to expand or collapse live intake details.")
        }
    }

    private func elapsedString(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed.rounded(.down))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

#if DEBUG
#Preview("Scan") {
    NavigationStack {
        ScanView(environment: PreviewFixtures.makeEnvironment(seedHistory: true))
    }
}
#endif
