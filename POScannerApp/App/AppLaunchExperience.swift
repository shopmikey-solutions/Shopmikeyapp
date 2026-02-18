//
//  AppLaunchExperience.swift
//  POScannerApp
//

import SwiftUI

struct AppLaunchExperience<Content: View>: View {
    @State private var hasFinishedLaunch: Bool = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .opacity(hasFinishedLaunch ? 1 : 0)

            if !hasFinishedLaunch {
                AppLaunchSplashView()
                    .transition(.opacity)
            }
        }
        .task {
            guard !hasFinishedLaunch else { return }
            try? await Task.sleep(nanoseconds: 280_000_000)
            withAnimation(.easeOut(duration: 0.28)) {
                hasFinishedLaunch = true
            }
        }
    }
}

private struct AppLaunchSplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)

                Text("ShopMikey")
                    .font(.title2.weight(.semibold))
            }
        }
    }
}

#if DEBUG
#Preview("Launch") {
    AppLaunchExperience {
        Color(uiColor: .systemBackground)
    }
}
#endif
