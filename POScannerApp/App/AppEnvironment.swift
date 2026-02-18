//
//  AppEnvironment.swift
//  POScannerApp
//

import Foundation
import SwiftUI

/// Lightweight dependency container injected through SwiftUI Environment.
struct AppEnvironment {
    let dataController: DataController
    let keychainService: KeychainService
    let secureStorage: SecureStorage
    let networkDiagnostics: NetworkDiagnosticsRecorder
    let reviewDraftStore: ReviewDraftStore
    let apiClient: APIClient
    let shopmonkeyAPI: ShopmonkeyAPI
    let ocrService: OCRService
    let poParser: POParser
    let foundationModelService: FoundationModelService
    let parseHandoffService: LocalParseHandoffService
}

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppEnvironment = .preview
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}

extension AppEnvironment {
    static var preview: AppEnvironment {
        let dataController = DataController(inMemory: true)
        let keychainService = KeychainService(service: "POScannerApp.preview")
        let secureStorage = SecureStorage(keychainService: keychainService)
        let networkDiagnostics = NetworkDiagnosticsRecorder.shared
        let reviewDraftStore = ReviewDraftStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview_review_drafts.json"))

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
            apiClient: apiClient,
            shopmonkeyAPI: ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics),
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService()
        )
    }
}
