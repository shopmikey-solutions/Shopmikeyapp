import Foundation
import Testing
@testable import ShopmikeyCoreNetworking

private final class CoreNetworkingInvariantURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct CoreNetworkingInvariantsTests {
    @Test func tokenProviderCalledPerRequest() async throws {
        CoreNetworkingInvariantURLProtocol.requestHandler = nil
        defer { CoreNetworkingInvariantURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreNetworkingInvariantURLProtocol.self]
        let session = URLSession(configuration: configuration)

        CoreNetworkingInvariantURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [:]
            ) else {
                throw URLError(.badServerResponse)
            }
            return (response, Data("{\"ok\":true}".utf8))
        }

        actor TokenCounter {
            private(set) var count: Int = 0

            func fetch() -> String {
                count += 1
                return "token-\(count)"
            }
        }

        struct OkResponse: Decodable {
            let ok: Bool
        }

        let counter = TokenCounter()
        let tokenProvider = TokenProviderActorAdapter(fetchToken: { await counter.fetch() })
        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            urlSession: session,
            tokenProvider: tokenProvider
        )

        let first: OkResponse = try await client.perform(
            .get,
            url: URL(string: "https://sandbox-api.shopmonkey.cloud/v3/order")!
        )
        let second: OkResponse = try await client.perform(
            .get,
            url: URL(string: "https://sandbox-api.shopmonkey.cloud/v3/vendor")!
        )

        #expect(first.ok)
        #expect(second.ok)
        #expect(await counter.count == 2)
    }

    @Test func loggingRedactsSensitiveHeadersAndQueryItems() {
        var request = URLRequest(url: URL(string: "https://sandbox-api.shopmonkey.cloud/v3/order?token=secret&trace=1")!)
        request.setValue("Bearer super-secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=abc", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let headers = NetworkingLogger.redactedHeaders(for: request)
        #expect(headers["Authorization"] == nil)
        #expect(headers["Cookie"] == nil)
        #expect(headers["Accept"] == "application/json")

        let endpoint = NetworkingLogger.sanitizedURLString(request.url)
        #expect(endpoint == "https://sandbox-api.shopmonkey.cloud/v3/order")
        #expect(!endpoint.contains("?"))
    }

    @Test func consumerSurfaceCompilesForIntendedEntryPoints() {
        let diagnostics = NetworkDiagnosticsRecorder(maxEntries: 10)
        let fallbackRecorder = ClosureFallbackAnalyticsRecorder { _, _ in }
        let tokenProvider = TokenProviderActorAdapter(fetchToken: { "token" })

        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            tokenProvider: tokenProvider,
            fallbackRecorder: fallbackRecorder,
            diagnosticsRecorder: diagnostics
        )
        let service = ShopmonkeyAPI(
            client: client,
            fallbackRecorder: fallbackRecorder,
            diagnosticsRecorder: diagnostics
        )

        let _: any ShopmonkeyServicing = service
        let _: APIError = .missingToken
        let _: NetworkDiagnosticsEntry? = nil
        let _: ShopmonkeyEndpointProbeReport? = nil
    }
}
