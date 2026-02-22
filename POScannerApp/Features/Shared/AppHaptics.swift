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
    static let eventNotification = Notification.Name("POScannerApp.AppHapticsEvent")

    static func selection() {
        post(.selection)
    }

    static func impact(_ style: ImpactStyle = .light, intensity: CGFloat = 1.0) {
        post(.impact(style, max(0, min(1, intensity))))
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
        switch type {
        case .success:
            post(.success)
        case .warning:
            post(.warning)
        case .error:
            post(.error)
        }
    }

    private static func post(_ event: Event) {
        guard shouldEmitHaptics else { return }
        NotificationCenter.default.post(
            name: eventNotification,
            object: event
        )
    }

    private static var shouldEmitHaptics: Bool {
#if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
#else
        return true
#endif
    }

    enum Event {
        case selection
        case success
        case warning
        case error
        case impact(ImpactStyle, CGFloat)
    }

    enum ImpactStyle: Hashable {
        case light
        case medium
        case heavy
        case soft
        case rigid
    }

    enum NotificationType {
        case success
        case warning
        case error
    }
}
