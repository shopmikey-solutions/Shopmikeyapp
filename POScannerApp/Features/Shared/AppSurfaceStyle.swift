//
//  AppSurfaceStyle.swift
//  POScannerApp
//

import SwiftUI

enum AppSurfaceStyle {
    static let cardStroke: Color = Color.white.opacity(0.10)
    static let sectionHeaderFont: Font = .system(.title3, design: .rounded).weight(.semibold)
    static let cardTitleFont: Font = .system(.title3, design: .rounded).weight(.semibold)
}

struct AppCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                .thinMaterial,
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
            .listRowBackground(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
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
