//
//  DeepLinks.swift
//  ShopMikey Scanner
//

import Foundation

enum DeepLinks {
    static let scheme = "shopmikey"

    static func scan(compose: Bool = false, draftID: UUID? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "scan"

        var queryItems: [URLQueryItem] = []
        if compose {
            queryItems.append(URLQueryItem(name: "compose", value: "1"))
        }
        if let draftID {
            queryItems.append(URLQueryItem(name: "draft", value: draftID.uuidString))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? URL(string: "\(scheme)://scan")!
    }

    static var history: URL {
        URL(string: "\(scheme)://history")!
    }

    static var settings: URL {
        URL(string: "\(scheme)://settings")!
    }
}
