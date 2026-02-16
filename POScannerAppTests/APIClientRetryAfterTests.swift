//
//  APIClientRetryAfterTests.swift
//  POScannerAppTests
//

import Foundation
import Testing
@testable import POScannerApp

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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

struct APIClientRetryAfterTests {
    @Test func retriesOnceOn429ThenThrowsRateLimited() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var callCount = 0
        StubURLProtocol.requestHandler = { request in
            callCount += 1
            guard let url = request.url else { throw URLError(.badURL) }

            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "0"]
            ) else {
                throw URLError(.badServerResponse)
            }
            return (response, Data())
        }

        actor SleepRecorder {
            var sleeps: [TimeInterval] = []
            func record(_ seconds: TimeInterval) {
                sleeps.append(seconds)
            }
        }

        let recorder = SleepRecorder()
        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            urlSession: session,
            tokenProvider: { "token" },
            sleeper: { seconds in await recorder.record(seconds) }
        )

        do {
            struct OkResponse: Decodable { let ok: Bool }
            _ = try await client.perform(.get, url: URL(string: "https://sandbox-api.shopmonkey.cloud/v3/purchase_order")!) as OkResponse
            #expect(Bool(false))
        } catch let error as APIError {
            if case .rateLimited = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }

        let sleeps = await recorder.sleeps
        #expect(callCount == 2)
        #expect(sleeps.count == 1)
    }
}
