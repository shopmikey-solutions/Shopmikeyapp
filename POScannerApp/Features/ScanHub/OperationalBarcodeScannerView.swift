//
//  OperationalBarcodeScannerView.swift
//  POScannerApp
//

import SwiftUI

struct OperationalBarcodeScannerView: View {
    let onScannedCode: (String) -> Void

    var body: some View {
        // Reuse shared scanner implementation; it already prefers VisionKit and handles unavailable devices safely.
        BarcodeScannerView { scannedCode in
            guard let scannedCode else { return }
            onScannedCode(scannedCode)
        }
    }
}
