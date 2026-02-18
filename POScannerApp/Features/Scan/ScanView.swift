//
//  ScanView.swift
//  POScannerApp
//

import SwiftUI
import VisionKit
import WebKit
import PhotosUI

struct ScanView: View {
    @AppStorage("ignoreTaxAndTotals") private var ignoreTaxAndTotals: Bool = false
    @State private var showScanner: Bool = false
    @State private var showSourceSheet: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingPhoto: Bool = false
    @State private var showArcade: Bool = false
    @State private var tapTimes: [Date] = []
    @State private var showProcessingDetails: Bool = true
    @StateObject private var viewModel: ScanViewModel
    private let arcadeTapTriggerEnabled: Bool = ProcessInfo.processInfo.arguments.contains("-enable-scanner-arcade")

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: ScanViewModel(environment: environment))
    }

    var body: some View {
        List {
            Section("Parts Intake Overview") {
                dashboardSummary
            }

            Section("Intake Preferences") {
                Toggle("Ignore tax and totals", isOn: $ignoreTaxAndTotals)
                    .accessibilityIdentifier("scan.ignoreTaxToggle")
                Text("Use this when supplier totals are noisy and line-item pricing is the source of truth.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("In-Progress Parts Intake") {
                if viewModel.inProgressDrafts.isEmpty {
                    Text("No saved intake drafts.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.inProgressDrafts) { draft in
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                AppHaptics.warning()
                                viewModel.deleteDraft(draft)
                            }
                        }
                    }
                }
            }

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

            if viewModel.uiTestReviewFixtureEnabled {
                Section {
                    Button("Open Review Fixture") {
                        viewModel.openUITestReviewFixture()
                    }
                    .accessibilityIdentifier("scan.openReviewFixture")
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .refreshable {
            viewModel.loadTodayMetrics()
        }
        .safeAreaPadding(.top, viewModel.isProcessing ? 116 : 0)
        .navigationTitle("ShopMikey")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard !showScanner, !viewModel.isProcessing, !isImportingPhoto else { return }
                    AppHaptics.impact(.medium, intensity: 0.9)
                    showSourceSheet = true
                } label: {
                    Label("Scan Parts Invoice", systemImage: "doc.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(showScanner || viewModel.isProcessing || isImportingPhoto)
                .accessibilityIdentifier("scan.scanButton")
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
        .fullScreenCover(isPresented: $showArcade) {
            NavigationStack {
            if let url = arcadeURL {
                ArcadeWebContainerView(url: url)
            } else {
                    ContentUnavailableView(
                        "Scanner Arcade Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Set a valid URL in Info.plist key ScannerArcadeURL.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showArcade = false }
                }
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
            viewModel.loadTodayMetrics()
            viewModel.loadInProgressDrafts()
            syncLiveActivity()
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
        .overlay(alignment: .topTrailing) {
            if arcadeTapTriggerEnabled {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 56, height: 56)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .onTapGesture {
                        registerArcadeTap()
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appOpenScanComposer)) { _ in
            guard !showScanner, !viewModel.isProcessing, !isImportingPhoto else { return }
            showSourceSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .appResumeScanDraft)) { notification in
            guard let draftID = notification.object as? UUID else { return }
            guard !viewModel.isProcessing else { return }
            Task {
                await viewModel.resumeDraft(id: draftID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewDraftStoreDidChange)) { _ in
            viewModel.loadInProgressDrafts()
        }
        .animation(.snappy(duration: 0.22), value: viewModel.inProgressDrafts)
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

    private func registerArcadeTap() {
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 1.2 }
        tapTimes.append(now)

        if tapTimes.count >= 3 {
            tapTimes.removeAll()
            showArcade = true
        }
    }

    private var arcadeURL: URL? {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "ScannerArcadeURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let raw = ((configured?.isEmpty == false)
            ? configured
            : "https://YOUR_DOMAIN/shopmikey-game/") ?? "https://YOUR_DOMAIN/shopmikey-game/"
        guard !raw.contains("YOUR_DOMAIN"),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased() else {
            return nil
        }

        if scheme == "https" {
            return url
        }

        let host = (url.host ?? "").lowercased()
        if scheme == "http", host == "127.0.0.1" || host == "localhost" {
            return url
        }

        return nil
    }

    private func syncLiveActivity() {
        PartsIntakeLiveActivityBridge.sync(
            isProcessing: viewModel.isProcessing,
            statusText: viewModel.processingStatusText,
            detailText: viewModel.processingDetailText,
            progress: viewModel.processingProgressEstimate
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
            List {
                Section {
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
                } footer: {
                    Text("Use camera for a new capture, or choose an existing invoice photo.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Parts Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280)])
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
                        .foregroundStyle(.blue)
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
                        .tint(.blue)

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

private struct ArcadeWebContainerView: View {
    let url: URL
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var reloadToken: UUID = UUID()

    var body: some View {
        ZStack {
            WebGameView(
                url: url,
                reloadToken: reloadToken,
                isLoading: $isLoading,
                loadError: $loadError
            )

            if isLoading {
                ProgressView("Loading Scanner Arcade…")
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .bottom) {
            if let errorText = loadError {
                VStack(spacing: 8) {
                    Text(errorText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        loadError = nil
                        isLoading = true
                        reloadToken = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
    }
}

private struct WebGameView: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    @Binding var isLoading: Bool
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, loadError: $loadError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken || webView.url == nil {
            context.coordinator.lastReloadToken = reloadToken
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
            webView.load(request)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let isLoading: Binding<Bool>
        private let loadError: Binding<String?>
        var lastReloadToken: UUID?

        init(isLoading: Binding<Bool>, loadError: Binding<String?>) {
            self.isLoading = isLoading
            self.loadError = loadError
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading.wrappedValue = true
            loadError.wrappedValue = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if let response = navigationResponse.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                isLoading.wrappedValue = false
                loadError.wrappedValue = "Could not load game (HTTP \(response.statusCode))."
            }
            return .allow
        }

        private func handleLoadFailure(_ error: Error) {
            isLoading.wrappedValue = false
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
                loadError.wrappedValue = "No internet connection."
            } else {
                loadError.wrappedValue = "Could not load Scanner Arcade."
            }
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
