//
//  AppSurfaceStyle.swift
//  POScannerApp
//

import SwiftUI

enum AppSurfaceStyle {
    static let accent: Color = Color(red: 0.98, green: 0.84, blue: 0.10)
    static let cardFill: LinearGradient = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.25, blue: 0.34).opacity(0.92),
            Color(red: 0.16, green: 0.22, blue: 0.31).opacity(0.92)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cardStroke: Color = Color.white.opacity(0.14)
    static let sectionHeaderFont: Font = .system(.title3, design: .rounded).weight(.semibold)
    static let cardTitleFont: Font = .system(.title3, design: .rounded).weight(.semibold)
}

struct AppCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                AppSurfaceStyle.cardFill,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppSurfaceStyle.cardStroke)
            )
    }
}

struct AppFormChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .listSectionSeparator(.hidden)
            .listRowSeparator(.hidden)
            .fontDesign(.rounded)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppSurfaceStyle.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppSurfaceStyle.cardStroke)
                    )
            )
    }
}

extension View {
    func appCardSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(AppCardSurfaceModifier(cornerRadius: cornerRadius))
    }

    func appFormChrome() -> some View {
        modifier(AppFormChromeModifier())
    }

    func appSectionHeaderStyle() -> some View {
        self
            .textCase(nil)
            .font(AppSurfaceStyle.sectionHeaderFont)
            .foregroundStyle(.white.opacity(0.86))
    }
}
