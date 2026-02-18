//
//  AppSurfaceStyle.swift
//  POScannerApp
//

import SwiftUI

enum AppSurfaceStyle {
    static let accent: Color = Color("AccentColor")
    static let info: Color = accent
    static let warning: Color = Color(uiColor: .systemOrange)
    static let success: Color = Color(uiColor: .systemGreen)
    static let listCardFill: Color = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardFill: LinearGradient = LinearGradient(
        colors: [
            Color(uiColor: .secondarySystemGroupedBackground),
            Color(uiColor: .tertiarySystemGroupedBackground)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cardStroke: Color = Color(uiColor: .separator).opacity(0.45)
    static let sectionHeaderFont: Font = .headline
    static let cardTitleFont: Font = .headline
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
            .listStyle(.plain)
            .listSectionSeparator(.hidden)
            .listRowSeparator(.hidden)
            .fontDesign(.rounded)
            .listRowBackground(AppListRowBackground())
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

struct AppListRowBackground: View {
    var cornerRadius: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppSurfaceStyle.listCardFill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppSurfaceStyle.cardStroke)
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
            .foregroundStyle(.secondary)
    }
}
