//
//  APIClient.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreDiagnostics

/// Supplies Bearer tokens for outbound API requests.
///
/// Implementations should return quickly and avoid long blocking work on the caller's execution context.
/// If token refresh is required, perform it asynchronously and ensure internal state is concurrency-safe.
public protocol TokenProvider: Sendable {
    func fetchBearerToken() async throws -> String
}

/// Actor-backed adapter that serializes token access for callers that want a single-flight fetch path.
public actor TokenProviderActorAdapter: TokenProvider {
    private let upstream: @Sendable () async throws -> String

    public init(provider: any TokenProvider) {
        self.upstream = { try await provider.fetchBearerToken() }
    }

    public init(fetchToken: @escaping @Sendable () async throws -> String) {
        self.upstream = fetchToken
    }

    public func fetchBearerToken() async throws -> String {
        try await upstream()
    }
}

public protocol FallbackAnalyticsRecording: Sendable {
    func record(branch: String, context: String) async
}

struct NoopFallbackAnalyticsRecorder: FallbackAnalyticsRecording {
    init() {}

    func record(branch: String, context: String) async {
        _ = branch
        _ = context
    }
}

struct ClosureTokenProvider: TokenProvider {
    private let closure: @Sendable () async throws -> String

    init(_ closure: @escaping @Sendable () async throws -> String) {
        self.closure = closure
    }

    init(_ closure: @escaping @Sendable () throws -> String) {
        self.closure = { try closure() }
    }

    func fetchBearerToken() async throws -> String {
        try await closure()
    }
}

public struct ClosureFallbackAnalyticsRecorder: FallbackAnalyticsRecording {
    private let closure: @Sendable (String, String) async -> Void

    public init(_ closure: @escaping @Sendable (String, String) async -> Void) {
        self.closure = closure
    }

    public func record(branch: String, context: String) async {
        await closure(branch, context)
    }
}

/// URLSession-backed client with strict Bearer auth and safe 429 Retry-After handling (single retry).
public final class APIClient: @unchecked Sendable {
    public enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
    }

    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let urlSession: URLSession
    private let tokenProvider: any TokenProvider
    private let sleeper: Sleeper
    private let diagnosticsRecorder: NetworkDiagnosticsRecorder
    private let fallbackRecorder: any FallbackAnalyticsRecording
    #if DEBUG
    private static let verboseConsoleLoggingEnabled: Bool = {
        let environmentValue = ProcessInfo.processInfo.environment["PO_SCANNER_VERBOSE_NETWORK_LOGS"]
        return environmentValue == "1"
    }()
    #endif

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(
        baseURL: URL,
        urlSession: URLSession = .shared,
        tokenProvider: any TokenProvider,
        sleeper: @escaping Sleeper = APIClient.defaultSleeper,
        fallbackRecorder: any FallbackAnalyticsRecording = NoopFallbackAnalyticsRecorder(),
        diagnosticsRecorder: NetworkDiagnosticsRecorder = .shared
    ) {
        // `baseURL` is intentionally ignored by the hardened client. Callers should supply full URLs.
        _ = baseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.sleeper = sleeper
        self.diagnosticsRecorder = diagnosticsRecorder
        self.fallbackRecorder = fallbackRecorder
    }

    public convenience init(
        baseURL: URL,
        urlSession: URLSession = .shared,
        tokenProvider: @escaping @Sendable () throws -> String,
        sleeper: @escaping Sleeper = APIClient.defaultSleeper,
        fallbackRecorder: any FallbackAnalyticsRecording = NoopFallbackAnalyticsRecorder(),
        diagnosticsRecorder: NetworkDiagnosticsRecorder = .shared
    ) {
        self.init(
            baseURL: baseURL,
            urlSession: urlSession,
            tokenProvider: ClosureTokenProvider(tokenProvider),
            sleeper: sleeper,
            fallbackRecorder: fallbackRecorder,
            diagnosticsRecorder: diagnosticsRecorder
        )
    }

    public func perform<Response: Decodable>(
        _ method: HTTPMethod,
        url: URL,
        body: Data? = nil
    ) async throws -> Response {
        let requestStart = Date()
        let requestID = UUID()
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        request = try await authorize(request)

        #if DEBUG
        if Self.verboseConsoleLoggingEnabled {
            print("➡️ Request: \(request.url?.absoluteString ?? "")")
        }
        #endif

        let (data, httpResponse) = try await send(
            request,
            method: method,
            didRetryOn429: false,
            didRetryTransientGET: false,
            startedAt: requestStart,
            requestID: requestID,
            attempt: 1
        )
        let requestDurationMillis = elapsedMillis(since: requestStart)
        do {
            let decoded = try decoder.decode(Response.self, from: data)
            await diagnosticsRecorder.record(
                NetworkDiagnosticsEntry(
                    method: method.rawValue,
                    url: url.absoluteString,
                    statusCode: httpResponse.statusCode,
                    durationMillis: requestDurationMillis,
                    requestBodyPreview: sanitizedPreview(from: body),
                    responseBodyPreview: sanitizedPreview(from: data),
                    errorSummary: nil
                )
            )
            return decoded
        } catch {
            NetworkingLogger.logRequestError(
                requestID: requestID,
                method: method.rawValue,
                url: request.url,
                error: APIError.decodingFailed,
                durationMillis: requestDurationMillis,
                attempt: 1
            )
            await diagnosticsRecorder.record(
                NetworkDiagnosticsEntry(
                    method: method.rawValue,
                    url: url.absoluteString,
                    statusCode: httpResponse.statusCode,
                    durationMillis: requestDurationMillis,
                    requestBodyPreview: sanitizedPreview(from: body),
                    responseBodyPreview: sanitizedPreview(from: data),
                    errorSummary: "Decoding failed"
                )
            )
            await fallbackRecorder.record(
                branch: FallbackBranch.apiDecodeFallback,
                context: "Decoding failed for \(method.rawValue)"
            )
            throw APIError.decodingFailed
        }
    }

    // MARK: - Internals

    func fetchBearerToken() async throws -> String {
        let token = try await tokenProvider.fetchBearerToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw APIError.missingToken
        }
        return token
    }

    private func authorize(_ request: URLRequest) async throws -> URLRequest {
        let token = try await fetchBearerToken()
        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return authorized
    }

    private func send(
        _ request: URLRequest,
        method: HTTPMethod,
        didRetryOn429: Bool,
        didRetryTransientGET: Bool,
        startedAt: Date,
        requestID: UUID,
        attempt: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let redactedHeaders = NetworkingLogger.redactedHeaders(for: request)
        NetworkingLogger.logRequestStart(
            requestID: requestID,
            method: method.rawValue,
            url: request.url,
            timeout: request.timeoutInterval,
            attempt: attempt,
            headers: redactedHeaders
        )

        let dataAndResponse: (Data, URLResponse)
        do {
            dataAndResponse = try await urlSession.data(for: request)
        } catch {
            NetworkingLogger.logRequestError(
                requestID: requestID,
                method: method.rawValue,
                url: request.url,
                error: error,
                durationMillis: elapsedMillis(since: startedAt),
                attempt: attempt
            )
            if method == .get,
               !didRetryTransientGET,
               shouldRetryTransientNetworkError(error) {
                await fallbackRecorder.record(
                    branch: FallbackBranch.submitRetryPath,
                    context: "Transient network retry"
                )
                await diagnosticsRecorder.record(
                    entry(
                        for: request,
                        statusCode: nil,
                        responseData: nil,
                        durationMillis: elapsedMillis(since: startedAt),
                        errorSummary: "Transient network error; retrying once"
                    )
                )
                try await sleeper(0.8)
                return try await send(
                    request,
                    method: method,
                    didRetryOn429: didRetryOn429,
                    didRetryTransientGET: true,
                    startedAt: startedAt,
                    requestID: requestID,
                    attempt: attempt + 1
                )
            }

            await diagnosticsRecorder.record(
                entry(
                    for: request,
                    statusCode: nil,
                    responseData: nil,
                    durationMillis: elapsedMillis(since: startedAt),
                    errorSummary: error.localizedDescription
                )
            )
            throw APIError.network(error)
        }

        let (data, response) = dataAndResponse
        guard let http = response as? HTTPURLResponse else {
            NetworkingLogger.logRequestError(
                requestID: requestID,
                method: method.rawValue,
                url: request.url,
                error: URLError(.badServerResponse),
                durationMillis: elapsedMillis(since: startedAt),
                attempt: attempt
            )
            throw APIError.network(URLError(.badServerResponse))
        }

        NetworkingLogger.logRequestEnd(
            requestID: requestID,
            method: method.rawValue,
            url: request.url,
            statusCode: http.statusCode,
            durationMillis: elapsedMillis(since: startedAt),
            attempt: attempt
        )

        if http.statusCode == 429 {
            if !didRetryOn429,
               let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
               let delay = Double(retryAfter) {
                await fallbackRecorder.record(
                    branch: FallbackBranch.netRateLimitRetry,
                    context: "Retry-After \(delay)s"
                )
                await fallbackRecorder.record(
                    branch: FallbackBranch.submitRetryPath,
                    context: "HTTP 429 retry"
                )
                try await sleeper(delay)
                return try await send(
                    request,
                    method: method,
                    didRetryOn429: true,
                    didRetryTransientGET: didRetryTransientGET,
                    startedAt: startedAt,
                    requestID: requestID,
                    attempt: attempt + 1
                )
            }
            await diagnosticsRecorder.record(
                entry(
                    for: request,
                    statusCode: http.statusCode,
                    responseData: data,
                    durationMillis: elapsedMillis(since: startedAt),
                    errorSummary: "Rate limited"
                )
            )
            throw APIError.rateLimited
        }

        if method == .get,
           !didRetryTransientGET,
           isTransientServerStatus(http.statusCode) {
            await fallbackRecorder.record(
                branch: FallbackBranch.submitRetryPath,
                context: "Transient status \(http.statusCode)"
            )
            await diagnosticsRecorder.record(
                entry(
                    for: request,
                    statusCode: http.statusCode,
                    responseData: data,
                    durationMillis: elapsedMillis(since: startedAt),
                    errorSummary: "Transient server status; retrying once"
                )
            )
            try await sleeper(0.8)
            return try await send(
                request,
                method: method,
                didRetryOn429: didRetryOn429,
                didRetryTransientGET: true,
                startedAt: startedAt,
                requestID: requestID,
                attempt: attempt + 1
            )
        }

        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401:
            await diagnosticsRecorder.record(
                entry(
                    for: request,
                    statusCode: http.statusCode,
                    responseData: data,
                    durationMillis: elapsedMillis(since: startedAt),
                    errorSummary: "Unauthorized"
                )
            )
            throw APIError.unauthorized
        case 500...599:
            #if DEBUG
            logFailedResponse(
                statusCode: http.statusCode,
                request: request,
                response: http,
                data: data
            )
            #endif
            await diagnosticsRecorder.record(
                entry(
                    for: request,
                    statusCode: http.statusCode,
                    responseData: data,
                    durationMillis: elapsedMillis(since: startedAt),
                    errorSummary: "Server error"
                )
            )
            throw APIError.serverError(http.statusCode)
        default:
            // Deterministic: treat any other non-2xx as a server error code.
            #if DEBUG
            logFailedResponse(
                statusCode: http.statusCode,
                request: request,
                response: http,
                data: data
            )
            #endif
            await diagnosticsRecorder.record(
                entry(
                    for: request,
                    statusCode: http.statusCode,
                    responseData: data,
                    durationMillis: elapsedMillis(since: startedAt),
                    errorSummary: "HTTP \(http.statusCode)"
                )
            )
            throw APIError.serverError(http.statusCode)
        }
    }

    private func shouldRetryTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func isTransientServerStatus(_ statusCode: Int) -> Bool {
        statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(value)
        } catch {
            throw APIError.encodingFailed
        }
    }

    public static func defaultSleeper(_ seconds: TimeInterval) async throws {
        let clamped = max(0, seconds)
        let nanosDouble = clamped * 1_000_000_000
        let nanos = UInt64(min(nanosDouble, Double(UInt64.max)))
        try await Task.sleep(nanoseconds: nanos)
    }

    private func entry(
        for request: URLRequest,
        statusCode: Int?,
        responseData: Data?,
        durationMillis: Int?,
        errorSummary: String?
    ) -> NetworkDiagnosticsEntry {
        NetworkDiagnosticsEntry(
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "(unknown url)",
            statusCode: statusCode,
            durationMillis: durationMillis,
            requestBodyPreview: sanitizedPreview(from: request.httpBody),
            responseBodyPreview: sanitizedPreview(from: responseData),
            errorSummary: errorSummary
        )
    }

    private func elapsedMillis(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }

    private func sanitizedPreview(from data: Data?) -> String? {
        guard let data else { return nil }
        guard !data.isEmpty else { return nil }
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        // Keep enough payload for full request/response diagnostics during sandbox schema debugging.
        return String(raw.prefix(20_000))
    }

    #if DEBUG
    private func logFailedResponse(
        statusCode: Int,
        request: URLRequest,
        response: HTTPURLResponse,
        data: Data
    ) {
        guard Self.verboseConsoleLoggingEnabled else { return }
        let url = request.url?.absoluteString ?? "(unknown url)"
        print("⬅️ Response \(statusCode): \(url)")
        guard let preview = sanitizedPreview(from: data) else {
            return
        }
        let contentType = response
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? "unknown"
        if contentType.contains("application/json")
            || contentType.contains("application/problem+json")
            || contentType.contains("text/plain") {
            let trimmedPreview = String(preview.prefix(2_000))
            print("⬅️ Body: \(trimmedPreview)")
        } else {
            print("⬅️ Body omitted (\(data.count) bytes, content-type: \(contentType))")
        }
    }
    #endif
}

public struct NetworkDiagnosticsEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let method: String
    public let url: String
    public let statusCode: Int?
    public let durationMillis: Int?
    public let requestBodyPreview: String?
    public let responseBodyPreview: String?
    public let errorSummary: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        url: String,
        statusCode: Int?,
        durationMillis: Int? = nil,
        requestBodyPreview: String?,
        responseBodyPreview: String?,
        errorSummary: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.durationMillis = durationMillis
        self.requestBodyPreview = requestBodyPreview
        self.responseBodyPreview = responseBodyPreview
        self.errorSummary = errorSummary
    }

    public var oneLineSummary: String {
        let status = statusCode.map(String.init) ?? "n/a"
        let duration = durationMillis.map { "\($0)ms" } ?? "n/a"
        if let errorSummary, !errorSummary.isEmpty {
            return "[\(status)] \(method) \(url) (\(duration)) - \(errorSummary)"
        }
        return "[\(status)] \(method) \(url) (\(duration))"
    }

    public var isFailure: Bool {
        if let statusCode {
            return !(200...299).contains(statusCode)
        }
        return errorSummary != nil
    }
}

public actor NetworkDiagnosticsRecorder {
    public static let shared = NetworkDiagnosticsRecorder()

    private let maxEntries: Int
    private var entries: [NetworkDiagnosticsEntry]

    public init(maxEntries: Int = 300) {
        self.maxEntries = maxEntries
        self.entries = []
    }

    public func record(_ entry: NetworkDiagnosticsEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    public func latest(limit: Int = 120) -> [NetworkDiagnosticsEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    public func exportText(limit: Int = 200) -> String {
        let clipped = Array(entries.prefix(max(0, limit)))
        if clipped.isEmpty {
            return "No captured network entries."
        }

        return clipped.map { entry in
            var lines: [String] = []
            lines.append("\(entry.timestamp.formatted(date: .abbreviated, time: .standard)) | \(entry.oneLineSummary)")
            if let requestBodyPreview = entry.requestBodyPreview, !requestBodyPreview.isEmpty {
                lines.append("request: \(requestBodyPreview)")
            }
            if let responseBodyPreview = entry.responseBodyPreview, !responseBodyPreview.isEmpty {
                lines.append("response: \(responseBodyPreview)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    public func latestFailure(
        urlContains: String? = nil,
        method: String? = nil,
        since: Date? = nil
    ) -> NetworkDiagnosticsEntry? {
        entries.first { entry in
            guard entry.isFailure else { return false }

            if let urlContains, !entry.url.localizedCaseInsensitiveContains(urlContains) {
                return false
            }

            if let method,
               entry.method.caseInsensitiveCompare(method) != .orderedSame {
                return false
            }

            if let since, entry.timestamp < since {
                return false
            }

            return true
        }
    }

    public func latestFailureSummary(since: Date? = nil) -> String? {
        guard let failure = latestFailure(since: since) else {
            return nil
        }
        var summary = failure.oneLineSummary
        if let requestBodyPreview = failure.requestBodyPreview, !requestBodyPreview.isEmpty {
            summary += " | request: \(requestBodyPreview)"
        }
        if let responseBodyPreview = failure.responseBodyPreview, !responseBodyPreview.isEmpty {
            summary += " | response: \(responseBodyPreview)"
        }
        return summary
    }
}
