//
//  AppDeepLink.swift
//  POScannerApp
//

import Foundation

enum AppDeepLink {
    enum Route: Equatable {
        case scan(openComposer: Bool, draftID: UUID?)
        case history
        case settings
    }

    private static let appScheme = DeepLinks.scheme
    private static let webHostSuffix = "shopmikey.app"

    static func parse(_ url: URL) -> Route? {
        if url.scheme?.lowercased() == appScheme {
            return parseAppScheme(url)
        }
        if let host = url.host?.lowercased(),
           host.hasSuffix(webHostSuffix) {
            return parseWebURL(url)
        }
        return nil
    }

    static func scanURL(openComposer: Bool = false, draftID: UUID? = nil) -> URL {
        DeepLinks.scan(compose: openComposer, draftID: draftID)
    }

    static var historyURL: URL { DeepLinks.history }
    static var settingsURL: URL { DeepLinks.settings }

    private static func parseAppScheme(_ url: URL) -> Route? {
        switch primaryRouteComponent(from: url) {
        case "scan":
            return .scan(
                openComposer: shouldOpenComposer(from: url),
                draftID: draftID(from: url)
            )
        case "history":
            return .history
        case "settings":
            return .settings
        default:
            return nil
        }
    }

    private static func parseWebURL(_ url: URL) -> Route? {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if path.hasPrefix("scan") {
            return .scan(
                openComposer: shouldOpenComposer(from: url),
                draftID: draftID(from: url)
            )
        }
        if path.hasPrefix("history") {
            return .history
        }
        if path.hasPrefix("settings") {
            return .settings
        }
        return nil
    }

    private static func primaryRouteComponent(from url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host.lowercased()
        }

        return url.pathComponents
            .drop { $0 == "/" }
            .first?
            .lowercased() ?? ""
    }

    private static func shouldOpenComposer(from url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let compose = components.queryItems?.first(where: { $0.name.lowercased() == "compose" })?.value else {
            return false
        }
        return ["1", "true", "yes"].contains(compose.lowercased())
    }

    private static func draftID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name.lowercased() == "draft" })?.value else {
            return nil
        }
        return UUID(uuidString: value)
    }
}

extension Notification.Name {
    static let appDeepLinkRequested = Notification.Name("POScannerApp.appDeepLinkRequested")
    static let appOpenScanComposer = Notification.Name("POScannerApp.appOpenScanComposer")
    static let appResumeScanDraft = Notification.Name("POScannerApp.appResumeScanDraft")
}
