import SwiftUI
import ShopmikeyCoreModels
import UIKit
import XCTest
@testable import POScannerApp

@MainActor
final class OCRReviewSnapshotTests: XCTestCase {
    func testOCRReviewLightDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "OCRReview__light__L",
            view: makeView(),
            config: .lightDefault
        )
    }

    func testOCRReviewDarkDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "OCRReview__dark__L",
            view: makeView(),
            config: .darkDefault
        )
    }

    func testOCRReviewLightXXXL() {
        SnapshotTestSupport.assertSnapshot(
            name: "OCRReview__light__XXXL",
            view: makeView(),
            config: .lightXXXL
        )
    }

    private func makeView() -> some View {
        NavigationStack {
            OCRReviewView(
                draft: sampleDraft,
                onCancel: {},
                onContinue: { _, _ in }
            )
        }
    }

    private var sampleDraft: ScanViewModel.OCRReviewDraft {
        ScanViewModel.OCRReviewDraft(
            draftID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            image: sampleDocumentImage(),
            extraction: OCRService.DocumentExtraction(
                text: """
                METRO AUTO PARTS
                BRK-100 Front Brake Pad Set 2 129.99
                OIL-200 Full Synthetic Oil 6 8.49
                INV-1001
                """,
                lines: [
                    OCRService.RecognizedLine(
                        text: "METRO AUTO PARTS",
                        confidence: 0.97,
                        boundingBox: CGRect(x: 0.10, y: 0.78, width: 0.62, height: 0.05)
                    ),
                    OCRService.RecognizedLine(
                        text: "BRK-100 Front Brake Pad Set 2 129.99",
                        confidence: 0.95,
                        boundingBox: CGRect(x: 0.10, y: 0.68, width: 0.78, height: 0.06)
                    ),
                    OCRService.RecognizedLine(
                        text: "OIL-200 Full Synthetic Oil 6 8.49",
                        confidence: 0.93,
                        boundingBox: CGRect(x: 0.10, y: 0.60, width: 0.74, height: 0.06)
                    ),
                    OCRService.RecognizedLine(
                        text: "INV-1001",
                        confidence: 0.90,
                        boundingBox: CGRect(x: 0.10, y: 0.52, width: 0.24, height: 0.05)
                    )
                ],
                barcodes: [
                    OCRService.DetectedBarcode(
                        payload: "BRK-100",
                        symbology: "CODE128",
                        confidence: 0.96,
                        boundingBox: CGRect(x: 0.12, y: 0.28, width: 0.54, height: 0.10)
                    )
                ]
            ),
            ignoreTaxAndTotals: true
        )
    }

    private func sampleDocumentImage() -> UIImage {
        let size = CGSize(width: 1179, height: 2556)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.90, alpha: 1).setFill()
            context.fill(CGRect(x: 52, y: 96, width: size.width - 104, height: size.height - 192))

            UIColor.black.setStroke()
            context.cgContext.setLineWidth(4)
            context.stroke(CGRect(x: 52, y: 96, width: size.width - 104, height: size.height - 192))

            UIColor.darkGray.setFill()
            let lineRects = [
                CGRect(x: 120, y: 360, width: 760, height: 36),
                CGRect(x: 120, y: 480, width: 900, height: 36),
                CGRect(x: 120, y: 600, width: 860, height: 36),
                CGRect(x: 120, y: 720, width: 260, height: 36)
            ]
            for rect in lineRects {
                context.fill(rect)
            }

            UIColor(red: 0.00, green: 0.56, blue: 0.62, alpha: 1.00).setFill()
            context.fill(CGRect(x: 140, y: 1480, width: 640, height: 160))
        }
    }
}
