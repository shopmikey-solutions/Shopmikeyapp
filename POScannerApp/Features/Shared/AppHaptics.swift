//
//  AppHaptics.swift
//  POScannerApp
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum AppHaptics {
    #if canImport(UIKit)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static var impactGenerators: [ImpactStyle: UIImpactFeedbackGenerator] = [:]
    #endif

    static func selection() {
        #if canImport(UIKit)
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
        #endif
    }

    static func impact(_ style: ImpactStyle = .light, intensity: CGFloat = 1.0) {
        #if canImport(UIKit)
        let generator: UIImpactFeedbackGenerator
        if let existing = impactGenerators[style] {
            generator = existing
        } else {
            let created = UIImpactFeedbackGenerator(style: style.uiKitStyle)
            impactGenerators[style] = created
            generator = created
        }
        generator.prepare()
        generator.impactOccurred(intensity: max(0, min(1, intensity)))
        #endif
    }

    static func success() {
        notify(.success)
    }

    static func warning() {
        notify(.warning)
    }

    static func error() {
        notify(.error)
    }

    private static func notify(_ type: NotificationType) {
        #if canImport(UIKit)
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(type.uiKitType)
        #endif
    }

    enum ImpactStyle: Hashable {
        case light
        case medium
        case heavy
        case soft
        case rigid

        #if canImport(UIKit)
        var uiKitStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light:
                return .light
            case .medium:
                return .medium
            case .heavy:
                return .heavy
            case .soft:
                return .soft
            case .rigid:
                return .rigid
            }
        }
        #endif
    }

    enum NotificationType {
        case success
        case warning
        case error

        #if canImport(UIKit)
        var uiKitType: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success:
                return .success
            case .warning:
                return .warning
            case .error:
                return .error
            }
        }
        #endif
    }
}
