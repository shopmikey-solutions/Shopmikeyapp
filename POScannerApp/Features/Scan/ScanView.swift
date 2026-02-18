//
//  ScanView.swift
//  POScannerApp
//

import SwiftUI
import VisionKit
import WebKit

struct ScanView: View {
    @AppStorage("ignoreTaxAndTotals") private var ignoreTaxAndTotals: Bool = false
    @State private var showScanner: Bool = false
    @State private var showArcade: Bool = false
    @State private var tapTimes: [Date] = []
    @State private var showProcessingDetails: Bool = true
    @StateObject private var viewModel: ScanViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: ScanViewModel(environment: environment))
    }

    var body: some View {
        List {
            Section("Overview") {
                dashboardSummary
            }

            Section("Scan Options") {
                Toggle("Ignore tax and totals", isOn: $ignoreTaxAndTotals)
                    .accessibilityIdentifier("scan.ignoreTaxToggle")
                Text("Use this when vendor totals are noisy and line items are the source of truth.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Recent Submissions") {
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
                    Text("No recent submissions yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Navigation") {
                NavigationLink("History") {
                    HistoryView(environment: viewModel.environment)
                }
                .accessibilityIdentifier("scan.quickHistory")

                NavigationLink("Settings") {
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

            if viewModel.isProcessing {
                Section {
                    ScanProcessingWidget(
                        startedAt: viewModel.processingStartedAt ?? Date(),
                        statusText: viewModel.processingStatusText,
                        detailText: viewModel.processingDetailText,
                        progress: viewModel.processingProgressEstimate,
                        showsDetail: $showProcessingDetails
                    )
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
        .navigationTitle("Purchase Orders")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan", systemImage: "doc.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scan.scanButton")
            }
        }
        .sheet(isPresented: $showScanner) {
            if VNDocumentCameraViewController.isSupported {
                VisionDocumentScanner(
                    onScan: { image, cgImage, orientation in
                        showScanner = false
                        viewModel.handleScannedImage(
                            image,
                            cgImage: cgImage,
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
                    description: Text("Document scanning is not supported on this device.")
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
            ReviewView(environment: viewModel.environment, parsedInvoice: route.invoice)
        }
        .onAppear {
            viewModel.loadTodayMetrics()
        }
        .overlay(alignment: .topTrailing) {
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

    private var dashboardSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scanner Dashboard")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("scan.dashboardTitle")

            Text("Scan invoices, catch exceptions early, and keep purchase orders moving.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                metricCell(title: "Scans Today", value: "\(viewModel.todayCount)")
                metricCell(title: "Submitted", value: "\(viewModel.submittedCount)")
                metricCell(title: "Failed", value: "\(viewModel.failedCount)")
            }

            ProgressView(value: pipelineProgress) {
                Text("Submission Sync")
                    .font(.subheadline.weight(.medium))
            } currentValueLabel: {
                Text("\(Int((pipelineProgress * 100).rounded()))%")
                    .font(.footnote)
            }

            LabeledContent("Today Total", value: viewModel.todayTotalFormatted)
            LabeledContent("Average Ticket", value: viewModel.todayAverageFormatted)
        }
        .padding(.vertical, 4)
    }

    private func metricCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
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
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse.byLayer, options: .repeating, value: progress)
                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(elapsedString(elapsed))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if showsDetail {
                    ProgressView(value: progress)
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.24)) {
                    showsDetail.toggle()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Double-tap to expand or collapse live processing details.")
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
