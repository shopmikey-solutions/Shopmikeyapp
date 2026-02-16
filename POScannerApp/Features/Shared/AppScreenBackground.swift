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
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.10, blue: 0.16),
                    Color(red: 0.10, green: 0.16, blue: 0.24),
                    style == .dashboard
                        ? Color(red: 0.14, green: 0.20, blue: 0.30)
                        : Color(red: 0.12, green: 0.18, blue: 0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(style == .dashboard ? 0.24 : 0.14))
                .frame(width: style == .dashboard ? 320 : 260, height: style == .dashboard ? 320 : 260)
                .blur(radius: style == .dashboard ? 80 : 70)
                .offset(x: 160, y: -250)

            if style == .dashboard {
                Circle()
                    .fill(Color.indigo.opacity(0.22))
                    .frame(width: 280, height: 280)
                    .blur(radius: 80)
                    .offset(x: -170, y: -230)
            } else {
                Circle()
                    .fill(Color.indigo.opacity(0.14))
                    .frame(width: 220, height: 220)
                    .blur(radius: 70)
                    .offset(x: -120, y: -170)
            }
        }
        .ignoresSafeArea()
    }
}
