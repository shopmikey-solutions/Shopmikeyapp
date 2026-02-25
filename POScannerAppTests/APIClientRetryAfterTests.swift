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

@Suite(.serialized)
struct APIClientRetryAfterTests {
    @Test func retriesOnceOn429ThenThrowsRateLimited() async throws {
        StubURLProtocol.requestHandler = nil
        defer { StubURLProtocol.requestHandler = nil }
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

    @Test func retriesOnceOnTransientGetServerErrorThenSucceeds() async throws {
        StubURLProtocol.requestHandler = nil
        defer { StubURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var callCount = 0
        StubURLProtocol.requestHandler = { request in
            callCount += 1
            guard let url = request.url else { throw URLError(.badURL) }
            if callCount == 1 {
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: 504,
                    httpVersion: nil,
                    headerFields: [:]
                ) else {
                    throw URLError(.badServerResponse)
                }
                return (response, Data())
            }

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

        actor SleepRecorder {
            var sleeps: [TimeInterval] = []
            func record(_ seconds: TimeInterval) {
                sleeps.append(seconds)
            }
        }

        struct OkResponse: Decodable { let ok: Bool }
        let recorder = SleepRecorder()
        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            urlSession: session,
            tokenProvider: { "token" },
            sleeper: { seconds in await recorder.record(seconds) }
        )

        let response: OkResponse = try await client.perform(
            .get,
            url: URL(string: "https://sandbox-api.shopmonkey.cloud/v3/purchase_order")!
        )

        #expect(response.ok == true)
        #expect(callCount == 2)
        let sleeps = await recorder.sleeps
        #expect(sleeps.count == 1)
    }

    @Test func doesNotRetryPostOnTransientServerError() async throws {
        StubURLProtocol.requestHandler = nil
        defer { StubURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var callCount = 0
        StubURLProtocol.requestHandler = { request in
            callCount += 1
            guard let url = request.url else { throw URLError(.badURL) }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 504,
                httpVersion: nil,
                headerFields: [:]
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

        struct OkResponse: Decodable { let ok: Bool }
        let recorder = SleepRecorder()
        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            urlSession: session,
            tokenProvider: { "token" },
            sleeper: { seconds in await recorder.record(seconds) }
        )

        do {
            _ = try await client.perform(
                .post,
                url: URL(string: "https://sandbox-api.shopmonkey.cloud/v3/purchase_order")!,
                body: Data("{}".utf8)
            ) as OkResponse
            #expect(Bool(false))
        } catch let error as APIError {
            if case .serverError(let code) = error {
                #expect(code == 504)
            } else {
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }

        #expect(callCount == 1)
        let sleeps = await recorder.sleeps
        #expect(sleeps.isEmpty)
    }

    @Test func retriesOnceOnTransientGetNetworkErrorThenSucceeds() async throws {
        StubURLProtocol.requestHandler = nil
        defer { StubURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var callCount = 0
        StubURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                throw URLError(.timedOut)
            }

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

        actor SleepRecorder {
            var sleeps: [TimeInterval] = []
            func record(_ seconds: TimeInterval) {
                sleeps.append(seconds)
            }
        }

        struct OkResponse: Decodable { let ok: Bool }
        let recorder = SleepRecorder()
        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            urlSession: session,
            tokenProvider: { "token" },
            sleeper: { seconds in await recorder.record(seconds) }
        )

        let response: OkResponse = try await client.perform(
            .get,
            url: URL(string: "https://sandbox-api.shopmonkey.cloud/v3/purchase_order")!
        )

        #expect(response.ok == true)
        #expect(callCount == 2)
        let sleeps = await recorder.sleeps
        #expect(sleeps.count == 1)
    }
}
