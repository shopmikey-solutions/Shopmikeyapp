//
//  AppEnvironment.swift
//  POScannerApp
//

import Foundation
import SwiftUI

protocol DateProviding: Sendable {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
}

/// Lightweight dependency container injected through SwiftUI Environment.
struct AppEnvironment {
    let dataController: DataController
    let keychainService: KeychainService
    let secureStorage: SecureStorage
    let networkDiagnostics: NetworkDiagnosticsRecorder
    let reviewDraftStore: any ReviewDraftStoring
    let localNotificationService: LocalNotificationService
    let apiClient: APIClient
    let shopmonkeyAPI: any ShopmonkeyServicing
    let ocrService: OCRService
    let poParser: POParser
    let foundationModelService: FoundationModelService
    let parseHandoffService: LocalParseHandoffService
    let dateProvider: any DateProviding
}

private struct AppEnvironmentKey: EnvironmentKey {
    static var defaultValue: AppEnvironment {
        #if DEBUG
        // SwiftUI may touch environment defaults during test/bootstrap before root injection.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            NSLog("AppEnvironment not injected. Inject at app root.")
        }
        #endif
        return .preview
    }
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}

extension AppEnvironment {
    static func live() -> AppEnvironment {
        let dataController = DataController()
        let keychainService = KeychainService()
        let secureStorage = SecureStorage(keychainService: keychainService)
        let networkDiagnostics = NetworkDiagnosticsRecorder.shared
        let reviewDraftStore = ReviewDraftStore()
        let localNotificationService = LocalNotificationService()

        let apiClient = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            tokenProvider: {
                do {
                    return try keychainService.retrieveToken()
                } catch KeychainService.KeychainServiceError.itemNotFound {
                    throw APIError.missingToken
                } catch {
                    throw error
                }
            },
            diagnosticsRecorder: networkDiagnostics
        )

        return AppEnvironment(
            dataController: dataController,
            keychainService: keychainService,
            secureStorage: secureStorage,
            networkDiagnostics: networkDiagnostics,
            reviewDraftStore: reviewDraftStore,
            localNotificationService: localNotificationService,
            apiClient: apiClient,
            shopmonkeyAPI: ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics),
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService(),
            dateProvider: SystemDateProvider()
        )
    }

    static var preview: AppEnvironment {
        let dataController = DataController(inMemory: true)
        let keychainService = KeychainService(service: "POScannerApp.preview")
        let secureStorage = SecureStorage(keychainService: keychainService)
        let networkDiagnostics = NetworkDiagnosticsRecorder.shared
        let reviewDraftStore = ReviewDraftStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview_review_drafts.json"))
        let localNotificationService = LocalNotificationService()

        let apiClient = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            tokenProvider: { throw APIError.missingToken },
            diagnosticsRecorder: networkDiagnostics
        )

        return AppEnvironment(
            dataController: dataController,
            keychainService: keychainService,
            secureStorage: secureStorage,
            networkDiagnostics: networkDiagnostics,
            reviewDraftStore: reviewDraftStore,
            localNotificationService: localNotificationService,
            apiClient: apiClient,
            shopmonkeyAPI: ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics),
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService(),
            dateProvider: SystemDateProvider()
        )
    }

    #if DEBUG
    static func test(
        dataController: DataController = DataController(inMemory: true),
        reviewDraftStore: any ReviewDraftStoring = ReviewDraftStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("test_review_drafts.json"))
    ) -> AppEnvironment {
        let keychainService = KeychainService(service: "POScannerApp.test")
        let secureStorage = SecureStorage(keychainService: keychainService)
        let networkDiagnostics = NetworkDiagnosticsRecorder.shared
        let localNotificationService = LocalNotificationService()

        let apiClient = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            tokenProvider: { throw APIError.missingToken },
            diagnosticsRecorder: networkDiagnostics
        )

        return AppEnvironment(
            dataController: dataController,
            keychainService: keychainService,
            secureStorage: secureStorage,
            networkDiagnostics: networkDiagnostics,
            reviewDraftStore: reviewDraftStore,
            localNotificationService: localNotificationService,
            apiClient: apiClient,
            shopmonkeyAPI: ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics),
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService(),
            dateProvider: SystemDateProvider()
        )
    }
    #endif
}
