//
//  AppSensoryFeedback.swift
//  POScannerApp
//

import SwiftUI
import Combine

private struct AppSensoryFeedbackModifier: ViewModifier {
    @State private var selectionTrigger: Int = 0
    @State private var successTrigger: Int = 0
    @State private var warningTrigger: Int = 0
    @State private var errorTrigger: Int = 0
    @State private var impactTrigger: ImpactTrigger = .init()

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: AppHaptics.eventNotification)) { notification in
                guard let event = notification.object as? AppHaptics.Event else { return }
                switch event {
                case .selection:
                    selectionTrigger &+= 1
                case .success:
                    successTrigger &+= 1
                case .warning:
                    warningTrigger &+= 1
                case .error:
                    errorTrigger &+= 1
                case let .impact(style, intensity):
                    impactTrigger = ImpactTrigger(
                        token: impactTrigger.token &+ 1,
                        style: style,
                        intensity: Double(intensity)
                    )
                }
            }
            .sensoryFeedback(.selection, trigger: selectionTrigger)
            .sensoryFeedback(.success, trigger: successTrigger)
            .sensoryFeedback(.warning, trigger: warningTrigger)
            .sensoryFeedback(.error, trigger: errorTrigger)
            .sensoryFeedback(trigger: impactTrigger) { _, latest in
                switch latest.style {
                case .light:
                    return .impact(weight: .light, intensity: latest.intensity)
                case .medium:
                    return .impact(weight: .medium, intensity: latest.intensity)
                case .heavy:
                    return .impact(weight: .heavy, intensity: latest.intensity)
                case .soft:
                    return .impact(flexibility: .soft, intensity: latest.intensity)
                case .rigid:
                    return .impact(flexibility: .rigid, intensity: latest.intensity)
                }
            }
    }
}

private struct ImpactTrigger: Equatable {
    var token: Int = 0
    var style: AppHaptics.ImpactStyle = .medium
    var intensity: Double = 1.0
}

extension View {
    func appSensoryFeedback() -> some View {
        modifier(AppSensoryFeedbackModifier())
    }
}
