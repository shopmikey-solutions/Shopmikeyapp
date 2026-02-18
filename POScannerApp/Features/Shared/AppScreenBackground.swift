//
//  AppScreenBackground.swift
//  POScannerApp
//

import SwiftUI

struct AppScreenBackground: View {
    enum Style {
        case standard
        case dashboard
    }

    private let style: Style

    init(style: Style = .standard) {
        self.style = style
    }

    var body: some View {
        let isDashboard = style == .dashboard

        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.10, blue: 0.16),
                    Color(red: 0.10, green: 0.16, blue: 0.24),
                    Color(red: 0.14, green: 0.20, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 160, y: isDashboard ? -250 : -230)

            Circle()
                .fill(Color.indigo.opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: -170, y: -230)
        }
        .ignoresSafeArea()
    }
}
