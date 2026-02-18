//
//  AppDeepLink.swift
//  POScannerApp
//

import Foundation

enum AppDeepLink {
    enum Route: Equatable {
        case scan(openComposer: Bool)
        case history
        case settings
    }

    private static let scheme = "shopmikey"

    static func parse(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let primary = primaryRouteComponent(from: url)
        switch primary {
        case "scan":
            return .scan(openComposer: shouldOpenComposer(from: url))
        case "history":
            return .history
        case "settings":
            return .settings
        default:
            return nil
        }
    }

    static func scanURL(openComposer: Bool = false) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "scan"
        if openComposer {
            components.queryItems = [URLQueryItem(name: "compose", value: "1")]
        }
        return components.url ?? URL(string: "shopmikey://scan")!
    }

    static var historyURL: URL { URL(string: "shopmikey://history")! }
    static var settingsURL: URL { URL(string: "shopmikey://settings")! }

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
}

extension Notification.Name {
    static let appDeepLinkRequested = Notification.Name("POScannerApp.appDeepLinkRequested")
    static let appOpenScanComposer = Notification.Name("POScannerApp.appOpenScanComposer")
}
