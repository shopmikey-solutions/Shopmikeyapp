//
//  CenteredLoadingView.swift
//  POScannerApp
//

import SwiftUI

struct CenteredLoadingView: View {
    let label: LocalizedStringKey

    var body: some View {
        ZStack {
            Color.clear
            ProgressView(label)
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
