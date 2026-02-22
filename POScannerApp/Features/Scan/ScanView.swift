//
//  ScanView.swift
//  POScannerApp
//

import SwiftUI
import VisionKit
import PhotosUI
import os

struct ScanView: View {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.ScanCapture")

    private struct CaptureFlowActivityState: Equatable {
        let showSourceSheet: Bool
        let showScanner: Bool
        let showPhotoPicker: Bool
        let isImportingPhoto: Bool
    }

    private struct LiveActivityPayloadSignature: Equatable {
        let isActive: Bool
        let status: String
        let detail: String
        let progressBucket: Int
        let stageToken: String
        let deepLinkSignature: String
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
    @State private var lastInitialRefreshRequestAt: Date?
    @State private var lastResumeDraftRequestID: UUID?
    @State private var lastResumeDraftRequestAt: Date?
    @State private var activeResumeDraftID: UUID?
    @State private var captureFlowIntentStartedAt: Date?
    @State private var deepLinkResumeTask: Task<Void, Never>?
    @State private var deepLinkConsumeTask: Task<Void, Never>?
    @StateObject private var viewModel: ScanViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let resumeDraftRequestDedupInterval: TimeInterval = 8.0
    private let preferredDraftDefaultsKey = "liveActivityPreferredDraftID"
    private let activePresentedScanDraftDefaultsKey = "activePresentedScanDraftID"
    private let pendingResumeDraftDefaultsKey = "pendingResumeDraftID"
    private let pendingOpenComposerDefaultsKey = "pendingOpenScanComposer"

    private var captureFlowActivityState: CaptureFlowActivityState {
        CaptureFlowActivityState(
            showSourceSheet: self.showSourceSheet,
            showScanner: self.showScanner,
            showPhotoPicker: self.showPhotoPicker,
            isImportingPhoto: self.isImportingPhoto
        )
    }

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
                            Self.logger.debug("Camera capture completed. Routing image into OCR pipeline.")
                            self.viewModel.handleScannedImage(
                                image,
                                orientation: orientation,
                                ignoreTaxAndTotals: self.ignoreTaxAndTotals
                            )
                        },
                        onCancel: {
                            self.showScanner = false
                            Self.logger.debug("Camera capture cancelled.")
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
            guard self.isTabActive else { return }
            self.scheduleInitialDashboardRefresh(force: true)
            self.scheduleConsumePendingDeepLinkRequests(after: 140_000_000)
            self.updatePresentedDraftMarker()
        }
        .onDisappear {
            self.initialLoadTask?.cancel()
            self.initialLoadTask = nil
            self.draftStoreRefreshTask?.cancel()
            self.draftStoreRefreshTask = nil
            self.liveActivityEndTask?.cancel()
            self.liveActivityEndTask = nil
            self.deepLinkResumeTask?.cancel()
            self.deepLinkResumeTask = nil
            self.deepLinkConsumeTask?.cancel()
            self.deepLinkConsumeTask = nil
            self.activeResumeDraftID = nil
            UserDefaults.standard.removeObject(forKey: self.activePresentedScanDraftDefaultsKey)
        }
        .onChange(of: isTabActive) { _, active in
            if active {
                self.scheduleInitialDashboardRefresh()
                self.scheduleDraftStoreRefresh()
                self.syncLiveActivity()
                self.scheduleConsumePendingDeepLinkRequests(after: 140_000_000)
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
            if oldValue && !newValue {
                self.scheduleConsumePendingDeepLinkRequests(after: 220_000_000)
            }
        }
        .onChange(of: viewModel.parsedInvoiceRoute) { _, route in
            self.updatePresentedDraftMarker()
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
        .onChange(of: captureFlowActivityState) { _, _ in
            self.syncLiveActivity()
            self.clearCaptureFlowIntentIfIdle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appOpenScanComposer)) { _ in
            Task { @MainActor in
                await Task.yield()
                if self.canPresentCaptureFlow {
                    UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
                    self.presentCaptureFlow()
                } else if self.isCaptureFlowTransitionActive {
                    Self.logger.debug("Ignoring open-composer request because capture flow is already active.")
                    UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
                } else {
                    UserDefaults.standard.set(true, forKey: self.pendingOpenComposerDefaultsKey)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appResumeScanDraft)) { notification in
            guard let draftID = notification.object as? UUID else { return }
            Task { @MainActor in
                await Task.yield()
                self.requestResumeDraftFromDeepLink(draftID)
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
            self.clearCaptureFlowIntentIfIdle()
            self.scheduleConsumePendingDeepLinkRequests(after: 180_000_000)
        }
        .onChange(of: isReviewFlowPresented) { _, presented in
            self.updatePresentedDraftMarker()
            if !presented {
                self.scheduleConsumePendingDeepLinkRequests(after: 320_000_000)
            } else {
                self.captureFlowIntentStartedAt = nil
            }
        }
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
            isImportingPhoto ||
            isReviewFlowPresented
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
        guard self.canPresentCaptureFlow else { return }
        Self.logger.debug("Capture flow requested from scan surface.")
        self.captureFlowIntentStartedAt = self.captureFlowIntentStartedAt ?? Date()
        self.viewModel.prepareForNewCaptureSession()
        AppHaptics.impact(.medium, intensity: 0.9)
        self.presentCaptureSourcePicker()
        self.syncLiveActivity()
    }

    private func presentCaptureSourcePicker() {
        guard self.canPresentCaptureFlow else { return }
        Self.logger.debug("Presenting capture source sheet.")
        self.pendingCaptureSource = nil
        self.showSourceSheet = true
    }

    private func handleCaptureSourceSheetDismissed() {
        guard let pendingCaptureSource else {
            Self.logger.debug("Capture source sheet dismissed without selection.")
            self.clearCaptureFlowIntentIfIdle()
            return
        }
        guard !self.showScanner, !self.showPhotoPicker, !self.viewModel.isProcessing, !self.isImportingPhoto else { return }
        guard !self.isReviewFlowPresented else { return }
        self.pendingCaptureSource = nil

        switch pendingCaptureSource {
        case .camera:
            Self.logger.debug("Capture source selected: camera.")
            showScanner = true
        case .photos:
            Self.logger.debug("Capture source selected: photos.")
            showPhotoPicker = true
        }
    }

    private var additionalDrafts: [ReviewDraftSnapshot] {
        guard viewModel.inProgressDrafts.count > 1 else { return [] }
        return Array(viewModel.inProgressDrafts.dropFirst())
    }

    private var canPresentCaptureFlow: Bool {
        !self.showScanner
            && !self.showSourceSheet
            && !self.showPhotoPicker
            && !self.viewModel.isProcessing
            && !self.isImportingPhoto
            && !self.isReviewFlowPresented
    }

    private var isCaptureFlowTransitionActive: Bool {
        self.captureFlowIntentStartedAt != nil
            || self.showSourceSheet
            || self.showScanner
            || self.showPhotoPicker
            || self.isImportingPhoto
            || self.viewModel.isProcessing
    }

    @MainActor
    private func resumeDraftFromDeepLink(id draftID: UUID) async -> Bool {
        if await self.viewModel.resumeDraft(id: draftID) {
            return true
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return false }
        return await self.viewModel.resumeDraft(id: draftID)
    }

    @MainActor
    private func scheduleConsumePendingDeepLinkRequests(after delayNanos: UInt64 = 120_000_000) {
        self.deepLinkConsumeTask?.cancel()
        self.deepLinkConsumeTask = Task { @MainActor in
            if delayNanos > 0 {
                try? await Task.sleep(nanoseconds: delayNanos)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            self.consumePendingDeepLinkRequests()
        }
    }

    @MainActor
    private func consumePendingDeepLinkRequests() {
        guard !self.viewModel.isProcessing else { return }
        guard !self.isReviewFlowPresented else { return }
        guard !self.isCaptureFlowTransitionActive else { return }
        guard !self.showSourceSheet, !self.showPhotoPicker, !self.showScanner else { return }

        let defaults = UserDefaults.standard

        if let rawDraftID = defaults.string(forKey: self.pendingResumeDraftDefaultsKey),
           let draftID = UUID(uuidString: rawDraftID) {
            self.requestResumeDraftFromDeepLink(draftID)
            return
        }

        let shouldOpenComposer = defaults.bool(forKey: self.pendingOpenComposerDefaultsKey)
        guard shouldOpenComposer else { return }
        if self.canPresentCaptureFlow {
            defaults.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            self.presentCaptureFlow()
        }
    }

    @MainActor
    private func requestResumeDraftFromDeepLink(_ draftID: UUID) {
        if self.viewModel.parsedInvoiceRoute?.draftSnapshot?.id == draftID
            || self.viewModel.ocrReviewDraft?.draftID == draftID {
            UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            return
        }

        if self.viewModel.activeWorkflowDraftIDForLiveActivity == draftID,
           self.viewModel.isProcessing {
            UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            return
        }

        if self.viewModel.isProcessing
            || self.isReviewFlowPresented
            || self.showSourceSheet
            || self.showPhotoPicker
            || self.showScanner {
            UserDefaults.standard.set(draftID.uuidString, forKey: self.pendingResumeDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            return
        }

        if self.activeResumeDraftID == draftID, self.deepLinkResumeTask != nil {
            return
        }

        let now = Date()
        if let lastResumeDraftRequestID = self.lastResumeDraftRequestID,
           let lastResumeDraftRequestAt = self.lastResumeDraftRequestAt,
           lastResumeDraftRequestID == draftID,
           now.timeIntervalSince(lastResumeDraftRequestAt) < self.resumeDraftRequestDedupInterval {
            return
        }
        self.lastResumeDraftRequestID = draftID
        self.lastResumeDraftRequestAt = now
        self.activeResumeDraftID = draftID

        UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)

        self.deepLinkResumeTask?.cancel()
        self.deepLinkResumeTask = Task { @MainActor in
            defer {
                self.deepLinkResumeTask = nil
                self.activeResumeDraftID = nil
            }

            let resumed = await self.resumeDraftFromDeepLink(id: draftID)
            if resumed {
                self.syncLiveActivity()
                return
            }
            UserDefaults.standard.removeObject(forKey: self.preferredDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            self.viewModel.loadInProgressDrafts(force: true)
            self.syncLiveActivity()
        }
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
                self.presentCaptureFlow()
            } label: {
                Label("Start New Capture", systemImage: "camera.viewfinder")
            }
        }

        if canResume {
            Button {
                AppHaptics.selection()
                self.presentCaptureFlow()
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

        if !self.viewModel.isProcessing,
           !self.viewModel.isLoadingInProgressDrafts,
           self.viewModel.inProgressDrafts.isEmpty,
           !self.isReviewFlowPresented {
            UserDefaults.standard.removeObject(forKey: self.preferredDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingResumeDraftDefaultsKey)
            UserDefaults.standard.removeObject(forKey: self.pendingOpenComposerDefaultsKey)
            PartsIntakeLiveActivityBridge.sync(
                isActive: false,
                statusText: "",
                detailText: "",
                progress: 0,
                deepLinkURL: nil,
                stageToken: nil
            )
            return
        }

        self.liveActivityEndTask?.cancel()
        self.liveActivityEndTask = Task { @MainActor in
            defer { self.liveActivityEndTask = nil }
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

        if let capturePayload = self.captureFlowLiveActivityPayload() {
            return capturePayload
        }

        if let ocrDraft = self.viewModel.ocrReviewDraft {
            let lineCount = ocrDraft.extraction.lines.count
            let lineLabel = lineCount == 1 ? "line" : "lines"
            return (
                true,
                "Reviewing OCR",
                "\(lineCount) text \(lineLabel) detected.",
                0.45,
                AppDeepLink.scanURL(draftID: ocrDraft.draftID),
                "ocr"
            )
        }

        if let reviewDraft = self.viewModel.parsedInvoiceRoute?.draftSnapshot,
           let payload = self.liveActivityPayload(for: reviewDraft) {
            return payload
        }

        if let draft = self.liveActivityDraftCandidate(),
           let payload = self.liveActivityPayload(for: draft) {
            return payload
        }

        return (false, "", "", 0, nil, nil)
    }

    private func captureFlowLiveActivityPayload() -> (
        isActive: Bool,
        status: String,
        detail: String,
        progress: Double,
        deepLinkURL: URL?,
        stageToken: String?
    )? {
        guard !self.viewModel.isProcessing else { return nil }
        guard !self.isReviewFlowPresented else { return nil }
        let hasCaptureIntent =
            self.captureFlowIntentStartedAt != nil
            || self.showSourceSheet
            || self.showScanner
            || self.showPhotoPicker
            || self.isImportingPhoto
        guard hasCaptureIntent else { return nil }

        if self.showScanner {
            return (
                true,
                "Capturing invoice",
                "Step 1 of 4 • Align invoice inside the camera frame.",
                0.24,
                AppDeepLink.scanURL(openComposer: true),
                "capture"
            )
        }

        if self.isImportingPhoto {
            return (
                true,
                "Importing invoice",
                "Step 1 of 4 • Loading selected photo.",
                0.24,
                AppDeepLink.scanURL(openComposer: true),
                "capture"
            )
        }

        if self.showPhotoPicker {
            return (
                true,
                "Select invoice photo",
                "Step 1 of 4 • Choose a clear photo of the invoice.",
                0.22,
                AppDeepLink.scanURL(openComposer: true),
                "capture"
            )
        }

        return (
            true,
            "Prepare capture",
            "Step 1 of 4 • Choose camera or photos.",
            0.20,
            AppDeepLink.scanURL(openComposer: true),
            "capture"
        )
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
        let deepLinkSignature = payload.deepLinkURL?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LiveActivityPayloadSignature(
            isActive: payload.isActive,
            status: payload.status.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: payload.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            progressBucket: bucket,
            stageToken: payload.stageToken?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            deepLinkSignature: deepLinkSignature
        )
    }

    private func liveActivityDraftCandidate() -> ReviewDraftSnapshot? {
        let drafts = self.viewModel.inProgressDrafts
        guard !drafts.isEmpty else { return nil }
        let now = Date()
        let eligibleDrafts = drafts.filter { draft in
            guard draft.isLiveIntakeSession else { return false }
            return self.isStoredDraftEligibleForLiveActivity(draft, now: now)
        }
        guard !eligibleDrafts.isEmpty else { return nil }

        if let activeDraftID = self.viewModel.activeWorkflowDraftIDForLiveActivity,
           let activeDraft = eligibleDrafts.first(where: { $0.id == activeDraftID }) {
            return activeDraft
        }

        let sortedDrafts = eligibleDrafts
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return self.liveActivityDraftPriority(lhs.workflowState) > self.liveActivityDraftPriority(rhs.workflowState)
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        if let preferredID = self.preferredLiveActivityDraftID(),
           let preferred = eligibleDrafts.first(where: { $0.id == preferredID }),
           self.shouldPreferDraftForLiveActivity(preferred, over: sortedDrafts.first) {
            return preferred
        }

        return sortedDrafts.first
    }

    private func shouldPreferDraftForLiveActivity(
        _ preferredDraft: ReviewDraftSnapshot,
        over newestDraft: ReviewDraftSnapshot?
    ) -> Bool {
        guard let newestDraft else { return true }
        if preferredDraft.id == newestDraft.id { return true }
        return preferredDraft.updatedAt >= newestDraft.updatedAt
    }

    private func isStoredDraftEligibleForLiveActivity(_ draft: ReviewDraftSnapshot, now: Date) -> Bool {
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
        switch draft.workflowState {
        case .scanning, .parsing:
            // Only show these while they are truly in-flight (handled above by active workflow checks).
            return false
        case .ocrReview:
            // OCR review is only restorable when we still hold the extraction payload.
            return self.viewModel.canResumeOCRReview(draft)
        case .reviewReady, .reviewEdited, .submitting:
            return now.timeIntervalSince(draft.updatedAt) <= draft.liveActivityRecencyWindow
        case .failed:
            return false
        }
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

    private func preferredLiveActivityDraftID() -> UUID? {
        if let active = self.viewModel.activeWorkflowDraftIDForLiveActivity {
            return active
        }
        if let reviewDraftID = self.viewModel.parsedInvoiceRoute?.draftSnapshot?.id {
            return reviewDraftID
        }
        if let ocrDraftID = self.viewModel.ocrReviewDraft?.draftID {
            return ocrDraftID
        }
        guard let raw = UserDefaults.standard.string(forKey: self.preferredDraftDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private var isReviewFlowPresented: Bool {
        viewModel.parsedInvoiceRoute != nil || viewModel.ocrReviewDraft != nil
    }

    @MainActor
    private func updatePresentedDraftMarker() {
        if let reviewDraftID = self.viewModel.parsedInvoiceRoute?.draftSnapshot?.id {
            UserDefaults.standard.set(
                reviewDraftID.uuidString,
                forKey: self.activePresentedScanDraftDefaultsKey
            )
            return
        }
        if let ocrDraftID = self.viewModel.ocrReviewDraft?.draftID {
            UserDefaults.standard.set(
                ocrDraftID.uuidString,
                forKey: self.activePresentedScanDraftDefaultsKey
            )
            return
        }
        UserDefaults.standard.removeObject(forKey: self.activePresentedScanDraftDefaultsKey)
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !isImportingPhoto else { return }
        Self.logger.debug("Photo import started from capture flow.")
        isImportingPhoto = true
        defer {
            isImportingPhoto = false
            selectedPhotoItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                viewModel.errorMessage = "Could not load the selected photo."
                Self.logger.debug("Photo import failed: selected item could not be decoded.")
                AppHaptics.error()
                return
            }

            Self.logger.debug("Photo import completed. Routing image into OCR pipeline.")
            viewModel.handleScannedImage(
                image,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
        } catch is CancellationError {
            Self.logger.debug("Photo import cancelled.")
            return
        } catch {
            viewModel.errorMessage = "Could not load the selected photo."
            Self.logger.debug("Photo import failed with error.")
            AppHaptics.error()
        }
    }

    @MainActor
    private func clearCaptureFlowIntentIfIdle() {
        guard !self.showSourceSheet else { return }
        guard !self.showScanner else { return }
        guard !self.showPhotoPicker else { return }
        guard !self.isImportingPhoto else { return }
        guard !self.viewModel.isProcessing else { return }
        self.captureFlowIntentStartedAt = nil
    }

    @MainActor
    private func scheduleInitialDashboardRefresh(force: Bool = false) {
        let now = Date()
        if !force,
           let lastInitialRefreshRequestAt = self.lastInitialRefreshRequestAt,
           now.timeIntervalSince(lastInitialRefreshRequestAt) < 0.9 {
            return
        }
        self.lastInitialRefreshRequestAt = now
        guard self.initialLoadTask == nil else { return }
        self.initialLoadTask = Task { @MainActor in
            defer { self.initialLoadTask = nil }
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
        guard self.draftStoreRefreshTask == nil else { return }
        self.draftStoreRefreshTask = Task { @MainActor in
            defer { self.draftStoreRefreshTask = nil }
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
