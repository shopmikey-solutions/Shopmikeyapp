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
    @StateObject private var viewModel: ScanViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: ScanViewModel(environment: environment))
    }

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    metricsGrid
                    pipelineCard
                    scanOptionsCard
                    scanButton
                    recentCard
                    quickActionsCard

                    if viewModel.uiTestReviewFixtureEnabled {
                        Button("Open Review Fixture") {
                            viewModel.openUITestReviewFixture()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("scan.openReviewFixture")
                    }

                    if viewModel.isProcessing {
                        processingBanner
                    }

                    if let errorMessage = viewModel.errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Purchase Orders")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            if VNDocumentCameraViewController.isSupported {
                VisionDocumentScanner(
                    onScan: { cgImage, orientation in
                        showScanner = false
                        viewModel.handleScannedImage(
                            cgImage,
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
            // Hidden trigger for Scanner Arcade.
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

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.10, blue: 0.16),
                    Color(red: 0.10, green: 0.16, blue: 0.24),
                    Color(red: 0.14, green: 0.20, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(0.24))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 160, y: -250)

            Circle()
                .fill(Color.indigo.opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: -170, y: -230)
        }
        .ignoresSafeArea()
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scanner Dashboard")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .accessibilityIdentifier("scan.dashboardTitle")
            Text("Scan invoices, catch exceptions early, and keep purchase orders moving.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))

            HStack {
                statusChip(title: "\(viewModel.pendingCount) Pending", color: .orange)
                statusChip(title: "\(viewModel.failedCount) Failed", color: .red)
                statusChip(title: "\(viewModel.submittedCount) Submitted", color: .green)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.25, blue: 0.44).opacity(0.95),
                    Color(red: 0.09, green: 0.17, blue: 0.30).opacity(0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14))
        )
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricTile(title: "Scans Today", value: "\(viewModel.todayCount)", icon: "doc.text")
            metricTile(title: "Today Total", value: viewModel.todayTotalFormatted, icon: "dollarsign.circle")
            metricTile(title: "Avg Ticket", value: viewModel.todayAverageFormatted, icon: "chart.bar.doc.horizontal")
            metricTile(title: "Pending Sync", value: "\(viewModel.pendingCount)", icon: "arrow.triangle.2.circlepath")
        }
    }

    private func metricTile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Submission Pipeline")
                    .font(.headline)
                Spacer()
                Text("\(Int((pipelineProgress * 100).rounded()))% synced")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: pipelineProgress)

            HStack(spacing: 8) {
                statusChip(title: "\(viewModel.submittedCount) Done", color: .green)
                statusChip(title: "\(viewModel.pendingCount) Queue", color: .orange)
                if viewModel.failedCount > 0 {
                    statusChip(title: "\(viewModel.failedCount) Retry", color: .red)
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var pipelineProgress: Double {
        guard viewModel.todayCount > 0 else { return 0 }
        return min(1, Double(viewModel.submittedCount) / Double(viewModel.todayCount))
    }

    private var scanOptionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan Options")
                .font(.headline)
            Toggle("Ignore tax and totals", isOn: $ignoreTaxAndTotals)
                .accessibilityIdentifier("scan.ignoreTaxToggle")
            Text("Use this when vendor totals are noisy and line items are the source of truth.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusChip(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.16), in: Capsule())
    }

    private var scanButton: some View {
        Button {
            showScanner = true
        } label: {
            Label("Scan Document", systemImage: "doc.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.yellow)
        .accessibilityIdentifier("scan.scanButton")
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Most Recent Submission")
                    .font(.headline)
                Spacer()
                Text("Updated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let recent = viewModel.mostRecentSummary {
                Text(recent.vendor)
                    .font(.body.weight(.semibold))
                Text("\(recent.total) • \(recent.date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No recent submissions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.pendingCount > 0 {
                Text("\(viewModel.pendingCount) submitting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var quickActionsCard: some View {
        HStack(spacing: 10) {
            quickActionLink(
                title: "History",
                subtitle: "Retry and inspect",
                symbol: "clock.arrow.circlepath",
                accessibilityIdentifier: "scan.quickHistory"
            ) {
                HistoryView(environment: viewModel.environment)
            }

            quickActionLink(
                title: "Settings",
                subtitle: "API and diagnostics",
                symbol: "slider.horizontal.3",
                accessibilityIdentifier: "scan.quickSettings"
            ) {
                SettingsView(environment: viewModel.environment)
            }
        }
    }

    private func quickActionLink<Destination: View>(
        title: String,
        subtitle: String,
        symbol: String,
        accessibilityIdentifier: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var processingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Processing scan…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
