//
//  POScannerApp.swift
//  POScannerApp
//
//  Created by Michael Bordeaux on 2/15/26.
//

import SwiftUI

@main
struct POScannerApp: App {
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var appNotificationDelegate
    private let environment: AppEnvironment

    init() {
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

        let shopmonkeyAPI = ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics)

        self.environment = AppEnvironment(
            dataController: dataController,
            keychainService: keychainService,
            secureStorage: secureStorage,
            networkDiagnostics: networkDiagnostics,
            reviewDraftStore: reviewDraftStore,
            localNotificationService: localNotificationService,
            apiClient: apiClient,
            shopmonkeyAPI: shopmonkeyAPI,
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(\.appEnvironment, environment)
                .environment(\.managedObjectContext, environment.dataController.viewContext)
                .tint(AppSurfaceStyle.accent)
        }
    }
}
