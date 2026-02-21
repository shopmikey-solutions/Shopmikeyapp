//
//  ScanView.swift
//  POScannerApp
//

import SwiftUI
import VisionKit
import PhotosUI

struct ScanView: View {
    private struct LiveActivityPayloadSignature: Equatable {
        let isActive: Bool
        let status: String
        let detail: String
        let progressBucket: Int
        let stageToken: String
    }

    private enum PendingCaptureSource {
        case camera
        case photos
    }

    let isTabActive: Bool

    @AppStorage("ignoreTaxAndTotals") private var ignoreTaxAndTotals: Bool = false
    @State private var showScanner: Bool = false
    @State private var showSourceSheet: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var pendingCaptureSource: PendingCaptureSource?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingPhoto: Bool = false
    @State private var showProcessingDetails: Bool = true
    @State private var hasPerformedInitialLoad: Bool = false
    @State private var initialLoadTask: Task<Void, Never>?
    @State private var draftStoreRefreshTask: Task<Void, Never>?
    @State private var liveActivityEndTask: Task<Void, Never>?
    @State private var lastLiveActivitySignature: LiveActivityPayloadSignature?
    @State private var lastDashboardRefreshAt: Date?
    @State private var lastDraftReloadAt: Date?
    @State private var lastDraftStoreChangeAt: Date?
    @StateObject private var viewModel: ScanViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(environment: AppEnvironment, isTabActive: Bool = true) {
        self.isTabActive = isTabActive
        _viewModel = StateObject(wrappedValue: ScanViewModel(environment: environment))
    }

    var body: some View {
        scanList
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .refreshable {
            self.viewModel.loadTodayMetrics()
        }
        .sensoryFeedback(.selection, trigger: ignoreTaxAndTotals)
        .navigationTitle("ShopMikey")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarCaptureButton
            }
        }
        .sheet(isPresented: $showSourceSheet, onDismiss: self.handleCaptureSourceSheetDismissed) {
            ScanSourceSheet(
                onScanWithCamera: { self.pendingCaptureSource = .camera },
                onChooseFromPhotos: { self.pendingCaptureSource = .photos }
            )
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images,
            preferredItemEncoding: .current
        )
        .fullScreenCover(isPresented: $showScanner) {
            ZStack {
                Color.black.ignoresSafeArea()

                if VNDocumentCameraViewController.isSupported {
                    VisionDocumentScanner(
                        onScan: { image, orientation in
                            self.showScanner = false
                            self.viewModel.handleScannedImage(
                                image,
                                orientation: orientation,
                                ignoreTaxAndTotals: self.ignoreTaxAndTotals
                            )
                        },
                        onCancel: {
                            self.showScanner = false
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
            .ignoresSafeArea()
        }
        .sheet(item: $viewModel.ocrReviewDraft) { draft in
            NavigationStack {
                OCRReviewView(
                    draft: draft,
                    onCancel: {
                        self.viewModel.cancelOCRReview()
                    },
                    onContinue: { reviewedText, includeDetectedBarcodes in
                        self.viewModel.continueFromOCRReview(
                            editedText: reviewedText,
                            includeDetectedBarcodes: includeDetectedBarcodes
                        )
                    }
                )
            }
        }
        .navigationDestination(item: $viewModel.parsedInvoiceRoute) { route in
            ReviewView(
                environment: self.viewModel.environment,
                parsedInvoice: route.invoice,
                draftSnapshot: route.draftSnapshot
            )
        }
        .onAppear {
            if self.isTabActive {
                self.scheduleInitialDashboardRefresh()
            }
        }
        .onDisappear {
            self.initialLoadTask?.cancel()
            self.initialLoadTask = nil
            self.draftStoreRefreshTask?.cancel()
            self.draftStoreRefreshTask = nil
            self.liveActivityEndTask?.cancel()
            self.liveActivityEndTask = nil
        }
        .onChange(of: isTabActive) { _, active in
            if active {
                self.scheduleInitialDashboardRefresh()
                self.scheduleDraftStoreRefresh()
                self.syncLiveActivity()
            } else {
                self.initialLoadTask?.cancel()
                self.initialLoadTask = nil
                self.draftStoreRefreshTask?.cancel()
                self.draftStoreRefreshTask = nil
                if !self.viewModel.isProcessing {
                    self.syncLiveActivity()
                }
            }
        }
        .onChange(of: viewModel.processingStage) { _, stage in
            guard stage != nil else { return }
            AppHaptics.selection()
            if self.isTabActive || self.viewModel.isProcessing || self.lastLiveActivitySignature != nil {
                self.syncLiveActivity()
            }
        }
        .onChange(of: viewModel.isProcessing) { oldValue, newValue in
            if self.isTabActive || oldValue || newValue || self.lastLiveActivitySignature != nil {
                self.syncLiveActivity()
            }
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
            Task { await self.importPhoto(item) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appOpenScanComposer)) { _ in
            self.presentCaptureFlow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appResumeScanDraft)) { notification in
            guard let draftID = notification.object as? UUID else { return }
            guard !self.viewModel.isProcessing else { return }
            Task {
                let resumed = await self.viewModel.resumeDraft(id: draftID)
                if !resumed {
                    await MainActor.run {
                        self.presentCaptureSourcePicker()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDraftStoreDidChange)) { _ in
            guard !self.viewModel.isProcessing else { return }
            // While actively reviewing a draft, avoid high-frequency store reload churn from autosave.
            if self.isReviewFlowPresented {
                return
            }
            let now = Date()
            if let lastDraftStoreChangeAt = self.lastDraftStoreChangeAt,
               now.timeIntervalSince(lastDraftStoreChangeAt) < 0.75 {
                return
            }
            self.lastDraftStoreChangeAt = now

            let hasActiveLiveSession =
                (self.lastLiveActivitySignature?.isActive == true)
                || self.viewModel.activeWorkflowDraftIDForLiveActivity != nil
            guard self.isTabActive || hasActiveLiveSession else {
                return
            }
            self.scheduleDraftStoreRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if self.isTabActive || self.lastLiveActivitySignature?.isActive == true {
                self.scheduleDraftStoreRefresh()
            }
            if self.isTabActive || self.lastLiveActivitySignature != nil || !self.viewModel.inProgressDrafts.isEmpty {
                self.syncLiveActivity()
            }
        }
        .onChange(of: viewModel.inProgressDrafts) { _, _ in
            if self.viewModel.isProcessing || self.liveActivityDraftCandidate() != nil || (self.lastLiveActivitySignature?.isActive == true) {
                self.syncLiveActivity()
            }
        }
        .animation(.snappy(duration: 0.22), value: viewModel.inProgressDrafts)
    }

    private var scanList: some View {
        List {
            processingSection
            syncStatusSection
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
    private var processingSection: some View {
        if viewModel.isProcessing {
            Section("Intake Progress") {
                ScanProcessingWidget(
                    startedAt: viewModel.processingStartedAt ?? Date(),
                    statusText: viewModel.processingStatusText,
                    detailText: viewModel.processingDetailText,
                    progress: viewModel.processingProgressEstimate,
                    showsDetail: $showProcessingDetails
                )
                .accessibilityIdentifier("scan.processingInlineCard")
            }
        }
    }

    @ViewBuilder
    private var syncStatusSection: some View {
        if !viewModel.isProcessing && viewModel.isRefreshingAnyDashboardData {
            Section("Updating ShopMikey") {
                ScanRefreshStatusCard(
                    statusText: viewModel.refreshStatusText,
                    detailText: viewModel.refreshDetailText,
                    draftsTimestamp: viewModel.lastDraftRefreshAt,
                    dashboardTimestamp: viewModel.lastDashboardRefreshAt
                )
                .accessibilityIdentifier("scan.refreshStatusCard")
            }
        }
    }

    @ViewBuilder
    private var currentSessionSection: some View {
        if let latestDraft = viewModel.latestDraft {
            Section("Current Intake Session") {
                currentSessionSummary(latestDraft)
                currentSessionActions(for: latestDraft)
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
                                self.viewModel.deleteDraft(draft)
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
                    HistoryView(environment: self.viewModel.environment)
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
        Section("App Tools") {
            NavigationLink("Purchase Order History") {
                HistoryView(environment: self.viewModel.environment)
            }
            .accessibilityIdentifier("scan.quickHistory")

            NavigationLink("Settings") {
                SettingsView(environment: self.viewModel.environment)
            }
            .accessibilityIdentifier("scan.quickSettings")
        }
    }

    @ViewBuilder
    private var uiTestSection: some View {
        if viewModel.uiTestReviewFixtureEnabled {
            Section {
                Button("Open Review Fixture") {
                    self.viewModel.openUITestReviewFixture()
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
            self.presentCaptureFlow()
        } label: {
            Label(
                self.viewModel.latestDraft == nil ? "Scan Parts Invoice" : "New Capture",
                systemImage: "doc.viewfinder"
            )
        }
        .appPrimaryActionButton()
        .disabled(
            showScanner ||
            showSourceSheet ||
            showPhotoPicker ||
            viewModel.isProcessing ||
            isImportingPhoto
        )
        .accessibilityIdentifier("scan.scanButton")
        .accessibilityLabel(self.viewModel.latestDraft == nil ? "Scan parts invoice" : "Start new parts invoice capture")
        .accessibilityHint("Opens capture source options for camera or photos.")
    }

    @ViewBuilder
    private func draftRow(_ draft: ReviewDraftSnapshot) -> some View {
        if draft.canResumeInReview {
            Button {
                AppHaptics.selection()
                self.viewModel.resumeDraft(draft)
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
        guard !showScanner, !showSourceSheet, !showPhotoPicker, !viewModel.isProcessing, !isImportingPhoto else { return }
        AppHaptics.impact(.medium, intensity: 0.9)
        presentCaptureSourcePicker()
    }

    private func presentCaptureSourcePicker() {
        guard !showScanner, !showSourceSheet, !showPhotoPicker, !viewModel.isProcessing, !isImportingPhoto else { return }
        pendingCaptureSource = nil
        showSourceSheet = true
    }

    private func handleCaptureSourceSheetDismissed() {
        guard let pendingCaptureSource else { return }
        guard !showScanner, !showPhotoPicker, !viewModel.isProcessing, !isImportingPhoto else { return }
        self.pendingCaptureSource = nil

        switch pendingCaptureSource {
        case .camera:
            showScanner = true
        case .photos:
            showPhotoPicker = true
        }
    }

    private var additionalDrafts: [ReviewDraftSnapshot] {
        guard viewModel.inProgressDrafts.count > 1 else { return [] }
        return Array(viewModel.inProgressDrafts.dropFirst())
    }

    private func currentSessionSummary(_ draft: ReviewDraftSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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

            Label(journeyNextActionText(for: draft.workflowState), systemImage: "arrow.triangle.branch")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("scan.currentSessionCard")
    }

    @ViewBuilder
    private func currentSessionActions(for draft: ReviewDraftSnapshot) -> some View {
        let canResume = viewModel.canResumeOCRReview(draft) || draft.canResumeInReview

        if viewModel.canResumeOCRReview(draft) {
            Button {
                AppHaptics.selection()
                self.viewModel.resumeOCRReview(draft)
            } label: {
                Label("Review OCR Draft", systemImage: "text.viewfinder")
            }
        } else if draft.canResumeInReview {
            Button {
                AppHaptics.selection()
                self.viewModel.resumeDraft(draft)
            } label: {
                Label("Resume Intake Review", systemImage: "arrow.clockwise.circle")
            }
        } else {
            Button {
                AppHaptics.selection()
                self.presentCaptureSourcePicker()
            } label: {
                Label("Start New Capture", systemImage: "camera.viewfinder")
            }
        }

        if canResume {
            Button {
                AppHaptics.selection()
                self.presentCaptureSourcePicker()
            } label: {
                Label("Start New Capture", systemImage: "camera.viewfinder")
            }
        }

        Button(role: .destructive) {
            AppHaptics.warning()
            self.viewModel.deleteDraft(draft)
        } label: {
            Label("Remove Saved Session", systemImage: "trash")
        }

        if !draft.canResumeInReview {
            Text("This session cannot be resumed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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

    private var dashboardSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parts Intake Dashboard")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("scan.dashboardTitle")

            Text("Capture supplier invoices, classify parts and tires, and keep Shopmonkey purchase orders moving.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                metricCell(title: "Drafts", value: "\(viewModel.draftCount)")
                metricCell(title: "Needs Review", value: "\(viewModel.reviewQueueCount)")
                metricCell(title: "Submitted", value: "\(viewModel.submittedCount)")
            }

            ProgressView(value: viewModel.syncSuccessRate) {
                Text("Shopmonkey Sync Status")
                    .font(.subheadline.weight(.medium))
            } currentValueLabel: {
                Text("\(Int((viewModel.syncSuccessRate * 100).rounded()))%")
                    .font(.footnote.monospacedDigit())
                    .contentTransition(.numericText())
            }
            .animation(.smooth(duration: 0.28), value: viewModel.syncSuccessRate)

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
        .animation(.snappy(duration: 0.26), value: viewModel.pendingCount)
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

    private func journeyNextActionText(for state: ReviewDraftSnapshot.WorkflowState) -> String {
        switch state {
        case .scanning:
            return "Next: OCR will extract text from your invoice."
        case .ocrReview:
            return "Next: confirm OCR text, then continue to line-item parsing."
        case .parsing:
            return "Next: line items will be classified for review."
        case .reviewReady:
            return "Next: open draft and verify part, tire, and fee types."
        case .reviewEdited:
            return "Next: submit to Shopmonkey when details are correct."
        case .submitting:
            return "Next: wait for Shopmonkey response and submission confirmation."
        case .failed:
            return "Next: reopen draft, adjust details, and retry."
        }
    }

    private func syncLiveActivity() {
        let payload = self.liveActivityPayload()
        guard self.isTabActive || self.viewModel.isProcessing || payload.isActive || self.lastLiveActivitySignature != nil else { return }
        // Draft loads can briefly return empty and cause false inactive transitions.
        if !payload.isActive,
           self.viewModel.isLoadingInProgressDrafts,
           self.lastLiveActivitySignature?.isActive == true {
            return
        }
        let signature = self.liveActivitySignature(for: payload)
        if signature == self.lastLiveActivitySignature {
            return
        }
        self.lastLiveActivitySignature = signature

        if payload.isActive {
            self.liveActivityEndTask?.cancel()
            self.liveActivityEndTask = nil
            PartsIntakeLiveActivityBridge.sync(
                isActive: true,
                statusText: payload.status,
                detailText: payload.detail,
                progress: payload.progress,
                deepLinkURL: payload.deepLinkURL,
                stageToken: payload.stageToken
            )
            return
        }

        self.liveActivityEndTask?.cancel()
        self.liveActivityEndTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            let latestPayload = self.liveActivityPayload()
            if latestPayload.isActive {
                self.syncLiveActivity()
                return
            }
            let latestSignature = self.liveActivitySignature(for: latestPayload)
            guard latestSignature == self.lastLiveActivitySignature else { return }
            PartsIntakeLiveActivityBridge.sync(
                isActive: false,
                statusText: "",
                detailText: "",
                progress: 0,
                deepLinkURL: nil,
                stageToken: nil
            )
        }
    }

    private func liveActivityPayload() -> (
        isActive: Bool,
        status: String,
        detail: String,
        progress: Double,
        deepLinkURL: URL?,
        stageToken: String?
    ) {
        if self.viewModel.isProcessing, let stage = self.viewModel.processingStage {
            let activeDraftID = self.viewModel.activeWorkflowDraftIDForLiveActivity ?? self.viewModel.latestDraft?.id
            let status: String
            let detail: String
            let stageToken: String
            switch stage {
            case .extractingText:
                status = "Capturing invoice"
                detail = "Step 1 of 4 • Running on-device Vision OCR."
                stageToken = "capture"
            case .preparingReview:
                status = "Reviewing OCR"
                detail = "Step 2 of 4 • Preparing text and barcode highlights."
                stageToken = "ocr"
            case .parsing:
                status = "Parsing line items"
                detail = "Step 2 of 4 • Applying on-device AI + rules."
                stageToken = "parse"
            case .finalizing:
                status = "Draft ready"
                detail = "Step 3 of 4 • Open draft and verify before submit."
                stageToken = "draft"
            }
            return (
                true,
                status,
                detail,
                self.viewModel.processingProgressEstimate,
                activeDraftID.map { AppDeepLink.scanURL(draftID: $0) } ?? AppDeepLink.scanURL(openComposer: true),
                stageToken
            )
        }

        if let draft = self.liveActivityDraftCandidate(),
           let payload = self.liveActivityPayload(for: draft) {
            return payload
        }

        return (false, "", "", 0, nil, nil)
    }

    private func liveActivityPayload(for draft: ReviewDraftSnapshot) -> (
        isActive: Bool,
        status: String,
        detail: String,
        progress: Double,
        deepLinkURL: URL?,
        stageToken: String?
    )? {
        guard let mapped = draft.liveActivityPayload else { return nil }
        let trimmedWorkflowDetail = draft.state.workflowDetail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmedWorkflowDetail.flatMap { $0.isEmpty ? nil : $0 } ?? mapped.detail

        return (
            true,
            mapped.status,
            detail,
            min(1, max(0.02, mapped.progress)),
            AppDeepLink.scanURL(draftID: draft.id),
            draft.liveActivityStageToken
        )
    }

    private func liveActivitySignature(
        for payload: (
            isActive: Bool,
            status: String,
            detail: String,
            progress: Double,
            deepLinkURL: URL?,
            stageToken: String?
        )
    ) -> LiveActivityPayloadSignature {
        let bucket = Int((min(1, max(0, payload.progress)) * 100).rounded())
        return LiveActivityPayloadSignature(
            isActive: payload.isActive,
            status: payload.status.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: payload.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            progressBucket: bucket,
            stageToken: payload.stageToken?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
    }

    private func liveActivityDraftCandidate() -> ReviewDraftSnapshot? {
        let drafts = self.viewModel.inProgressDrafts
        guard !drafts.isEmpty else { return nil }
        let now = Date()

        return drafts
            .filter { draft in
                guard draft.isLiveIntakeSession else { return false }
                return self.isDraftEligibleForLiveActivity(draft, now: now)
            }
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    let lhsPriority = self.liveActivityDraftPriority($0.workflowState)
                    let rhsPriority = self.liveActivityDraftPriority($1.workflowState)
                    return lhsPriority > rhsPriority
                }
                return $0.updatedAt > $1.updatedAt
            }
            .first
    }

    private func isDraftEligibleForLiveActivity(_ draft: ReviewDraftSnapshot, now: Date) -> Bool {
        if self.viewModel.activeWorkflowDraftIDForLiveActivity == draft.id {
            return true
        }
        if let reviewDraftID = self.viewModel.parsedInvoiceRoute?.draftSnapshot?.id,
           reviewDraftID == draft.id {
            return true
        }
        if let ocrDraftID = self.viewModel.ocrReviewDraft?.draftID,
           ocrDraftID == draft.id {
            return true
        }
        let maxAge = draft.liveActivityRecencyWindow
        return now.timeIntervalSince(draft.updatedAt) <= maxAge
    }

    private func liveActivityDraftPriority(_ state: ReviewDraftSnapshot.WorkflowState) -> Int {
        switch state {
        case .submitting:
            return 5
        case .reviewEdited:
            return 4
        case .reviewReady:
            return 3
        case .parsing:
            return 2
        case .ocrReview:
            return 1
        case .scanning:
            return 0
        case .failed:
            return -1
        }
    }

    private var isReviewFlowPresented: Bool {
        viewModel.parsedInvoiceRoute != nil || viewModel.ocrReviewDraft != nil
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

    @MainActor
    private func scheduleInitialDashboardRefresh() {
        self.initialLoadTask?.cancel()
        self.initialLoadTask = Task { @MainActor in
            await Task.yield()
            let shouldForceMetricsReload = !self.hasPerformedInitialLoad
            if shouldForceMetricsReload {
                self.hasPerformedInitialLoad = true
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            self.refreshDashboard(forceMetricsReload: shouldForceMetricsReload)
        }
    }

    @MainActor
    private func scheduleDraftStoreRefresh() {
        self.draftStoreRefreshTask?.cancel()
        self.draftStoreRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.triggerDraftReloadIfNeeded(minimumInterval: 2.4)
        }
    }

    @MainActor
    private func refreshDashboard(forceMetricsReload: Bool) {
        triggerDraftReloadIfNeeded(minimumInterval: 2.2, force: false)

        let now = Date()
        let shouldReloadMetrics: Bool
        if forceMetricsReload {
            shouldReloadMetrics = true
        } else if let lastDashboardRefreshAt {
            shouldReloadMetrics = now.timeIntervalSince(lastDashboardRefreshAt) >= 2.0
        } else {
            shouldReloadMetrics = true
        }

        if shouldReloadMetrics {
            lastDashboardRefreshAt = now
            viewModel.loadTodayMetrics()
        }
    }

    @MainActor
    private func triggerDraftReloadIfNeeded(minimumInterval: TimeInterval, force: Bool = false) {
        let now = Date()
        if !force, let lastDraftReloadAt, now.timeIntervalSince(lastDraftReloadAt) < minimumInterval {
            return
        }
        lastDraftReloadAt = now
        viewModel.loadInProgressDrafts(force: force)
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
                        self.onScanWithCamera()
                        self.dismiss()
                    } label: {
                        Label("Scan with Camera", systemImage: "camera.viewfinder")
                    }

                    Button {
                        AppHaptics.selection()
                        self.onChooseFromPhotos()
                        self.dismiss()
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
                    Button("Done") { self.dismiss() }
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
            let elapsed = max(0, context.date.timeIntervalSince(self.startedAt))
            let normalizedProgress = self.clampedProgress(self.progress)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(AppSurfaceStyle.info)
                        .symbolEffect(.pulse.byLayer, options: .repeating, value: normalizedProgress)
                    Text(self.statusText)
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text(self.elapsedString(elapsed))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if self.showsDetail {
                    ProgressView(value: normalizedProgress)
                        .progressViewStyle(.linear)
                        .tint(AppSurfaceStyle.info)

                    Text(self.detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                AppHaptics.selection()
                withAnimation(.snappy(duration: 0.24)) {
                    self.showsDetail.toggle()
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

    private func clampedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0.02 }
        return min(1, max(0.02, value))
    }
}

private struct ScanRefreshStatusCard: View {
    let statusText: String
    let detailText: String
    let draftsTimestamp: Date?
    let dashboardTimestamp: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(statusText)
                    .font(.headline.weight(.semibold))
                Spacer()
            }

            Text(detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let timestampText = statusTimestampText {
                Text(timestampText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTimestampText: String? {
        let formatter = Date.FormatStyle(date: .omitted, time: .shortened)
        switch (draftsTimestamp, dashboardTimestamp) {
        case let (drafts?, dashboard?):
            return "Drafts updated \(drafts.formatted(formatter)) • Metrics updated \(dashboard.formatted(formatter))"
        case let (drafts?, nil):
            return "Drafts updated \(drafts.formatted(formatter))"
        case let (nil, dashboard?):
            return "Metrics updated \(dashboard.formatted(formatter))"
        case (nil, nil):
            return nil
        }
    }
}

#if DEBUG
#Preview("Scan") {
    NavigationStack {
        ScanView(environment: PreviewFixtures.makeEnvironment(seedHistory: true))
    }
}
#endif
