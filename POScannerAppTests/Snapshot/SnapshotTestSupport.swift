import SwiftUI
import ShopmikeyCoreModels
import UIKit
import XCTest

@MainActor
enum SnapshotTestSupport {
    private static let fixedSnapshotSize = CGSize(width: 393, height: 852)
    private static let fixedSnapshotScale: CGFloat = 2.0

    struct SnapshotConfig {
        let interfaceStyle: UIUserInterfaceStyle
        let dynamicTypeSize: DynamicTypeSize
        let dynamicTypeLabel: String

        static let lightDefault = SnapshotConfig(
            interfaceStyle: .light,
            dynamicTypeSize: .large,
            dynamicTypeLabel: "L"
        )

        static let darkDefault = SnapshotConfig(
            interfaceStyle: .dark,
            dynamicTypeSize: .large,
            dynamicTypeLabel: "L"
        )

        static let lightXXXL = SnapshotConfig(
            interfaceStyle: .light,
            dynamicTypeSize: .xxxLarge,
            dynamicTypeLabel: "XXXL"
        )
    }

    static func render<V: View>(view: V, config: SnapshotConfig) -> UIImage {
        renderDeterministic(
            view,
            size: fixedSnapshotSize,
            scale: fixedSnapshotScale,
            interfaceStyle: config.interfaceStyle,
            contentSizeCategory: contentSizeCategory(for: config.dynamicTypeSize)
        )
    }

    static func renderDeterministic<V: View>(
        _ view: V,
        size: CGSize,
        scale: CGFloat,
        interfaceStyle: UIUserInterfaceStyle,
        contentSizeCategory: ContentSizeCategory
    ) -> UIImage {
        let rootView = view
            .environment(\.colorScheme, interfaceStyle == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, dynamicTypeSize(for: contentSizeCategory))
            .environment(\.sizeCategory, contentSizeCategory)
            .environment(\.displayScale, scale)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? TimeZone(abbreviation: "UTC")!)
            .environment(\.calendar, Calendar(identifier: .gregorian))

        // Disable UIKit animations to remove frame-to-frame variance in snapshots.
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        let host = UIHostingController(rootView: rootView)
        host.overrideUserInterfaceStyle = interfaceStyle

        let container = UIView(frame: CGRect(origin: .zero, size: size))
        container.backgroundColor = interfaceStyle == .dark ? .black : .white

        host.view.frame = container.bounds
        host.view.backgroundColor = .clear
        container.addSubview(host.view)

        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            container.layer.render(in: ctx.cgContext)
        }

        host.view.removeFromSuperview()
        return image
    }

    private static func contentSizeCategory(for dynamicTypeSize: DynamicTypeSize) -> ContentSizeCategory {
        switch dynamicTypeSize {
        case .xSmall:
            return .extraSmall
        case .small:
            return .small
        case .medium:
            return .medium
        case .large:
            return .large
        case .xLarge:
            return .extraLarge
        case .xxLarge:
            return .extraExtraLarge
        case .xxxLarge:
            return .extraExtraExtraLarge
        case .accessibility1:
            return .accessibilityMedium
        case .accessibility2:
            return .accessibilityLarge
        case .accessibility3:
            return .accessibilityExtraLarge
        case .accessibility4:
            return .accessibilityExtraExtraLarge
        case .accessibility5:
            return .accessibilityExtraExtraExtraLarge
        @unknown default:
            return .large
        }
    }

    private static func dynamicTypeSize(for contentSizeCategory: ContentSizeCategory) -> DynamicTypeSize {
        switch contentSizeCategory {
        case .extraSmall:
            return .xSmall
        case .small:
            return .small
        case .medium:
            return .medium
        case .large:
            return .large
        case .extraLarge:
            return .xLarge
        case .extraExtraLarge:
            return .xxLarge
        case .extraExtraExtraLarge:
            return .xxxLarge
        case .accessibilityMedium:
            return .accessibility1
        case .accessibilityLarge:
            return .accessibility2
        case .accessibilityExtraLarge:
            return .accessibility3
        case .accessibilityExtraExtraLarge:
            return .accessibility4
        case .accessibilityExtraExtraExtraLarge:
            return .accessibility5
        default:
            return .large
        }
    }

    static func loadReferenceImage(name: String) -> UIImage? {
        UIImage(contentsOfFile: referenceImageURL(for: name).path)
    }

    static func assertSnapshot<V: View>(
        name: String,
        view: V,
        config: SnapshotConfig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let image = render(view: view, config: config)
        assertSnapshot(name: name, image: image, file: file, line: line)
    }

    static func assertSnapshot(
        name: String,
        image: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let baselineURL = referenceImageURL(for: name)

        if isRecordMode {
            do {
                try FileManager.default.createDirectory(
                    at: referenceImagesDirectoryURL,
                    withIntermediateDirectories: true
                )
                let pngData = try requirePNGData(image)
                try pngData.write(to: baselineURL, options: .atomic)
                return
            } catch {
                XCTFail(
                    "Failed to record baseline for \(name): \(error.localizedDescription)",
                    file: file,
                    line: line
                )
                return
            }
        }

        guard let expectedData = try? Data(contentsOf: baselineURL),
              let expectedImage = UIImage(data: expectedData) else {
            XCTFail(
                """
                Missing baseline for \(name).
                Expected baseline: \(baselineURL.path)
                Run: SNAPSHOT_RECORD=1 bash scripts/ci_release_gate.sh
                """,
                file: file,
                line: line
            )
            return
        }

        guard let expectedBuffer = rgbaBuffer(for: expectedImage),
              let actualBuffer = rgbaBuffer(for: image) else {
            XCTFail("Could not decode snapshot buffers for \(name).", file: file, line: line)
            return
        }

        if expectedBuffer.width == actualBuffer.width,
           expectedBuffer.height == actualBuffer.height,
           expectedBuffer.bytes == actualBuffer.bytes {
            return
        }

        let artifactsDir = snapshotArtifactsDirectory(for: name)
        do {
            try FileManager.default.createDirectory(
                at: artifactsDir,
                withIntermediateDirectories: true
            )
            let expectedPNG = try requirePNGData(expectedImage)
            let actualPNG = try requirePNGData(image)
            try expectedPNG.write(to: artifactsDir.appendingPathComponent("expected.png"), options: .atomic)
            try actualPNG.write(to: artifactsDir.appendingPathComponent("actual.png"), options: .atomic)

            if let diffImage = diffImage(expected: expectedBuffer, actual: actualBuffer),
               let diffPNG = diffImage.pngData() {
                try diffPNG.write(to: artifactsDir.appendingPathComponent("diff.png"), options: .atomic)
            }
        } catch {
            XCTFail(
                "Snapshot mismatch for \(name), and writing artifacts failed: \(error.localizedDescription)",
                file: file,
                line: line
            )
            return
        }

        XCTFail(
            """
            Snapshot mismatch for \(name).
            Baseline: \(baselineURL.path)
            Artifacts: \(artifactsDir.path)
            Run: SNAPSHOT_RECORD=1 bash scripts/ci_release_gate.sh
            """,
            file: file,
            line: line
        )
    }

    private struct RGBABuffer {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    private static var isRecordMode: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SNAPSHOT_RECORD"] == "1" {
            return true
        }
        if let markerPath = env["SNAPSHOT_RECORD_MARKER_PATH"], !markerPath.isEmpty {
            return FileManager.default.fileExists(atPath: markerPath)
        }
        return FileManager.default.fileExists(atPath: defaultRecordMarkerURL.path)
    }

    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Snapshot
            .deletingLastPathComponent() // POScannerAppTests
            .deletingLastPathComponent() // repo root
    }

    private static var referenceImagesDirectoryURL: URL {
        repoRootURL
            .appendingPathComponent("POScannerAppTests", isDirectory: true)
            .appendingPathComponent("Snapshot", isDirectory: true)
            .appendingPathComponent("ReferenceImages", isDirectory: true)
    }

    private static var snapshotsReportDirectoryURL: URL {
        repoRootURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("release-gate", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    private static var defaultRecordMarkerURL: URL {
        repoRootURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("release-gate", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent("snapshot_record_mode.txt", isDirectory: false)
    }

    private static func referenceImageURL(for name: String) -> URL {
        referenceImagesDirectoryURL.appendingPathComponent("\(name).png", isDirectory: false)
    }

    private static func snapshotArtifactsDirectory(for name: String) -> URL {
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return snapshotsReportDirectoryURL.appendingPathComponent(safeName, isDirectory: true)
    }

    private static func requirePNGData(_ image: UIImage) throws -> Data {
        guard let data = image.pngData() else {
            struct PNGEncodingError: LocalizedError {
                var errorDescription: String? { "Unable to encode snapshot image as PNG." }
            }
            throw PNGEncodingError()
        }
        return data
    }

    private static func rgbaBuffer(for image: UIImage) -> RGBABuffer? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow
        var raw = [UInt8](repeating: 0, count: totalBytes)

        guard let context = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBABuffer(bytes: raw, width: width, height: height)
    }

    private static func diffImage(expected: RGBABuffer, actual: RGBABuffer) -> UIImage? {
        let width = max(expected.width, actual.width)
        let height = max(expected.height, actual.height)
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var diff = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        func pixel(_ buffer: RGBABuffer, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
            guard x < buffer.width, y < buffer.height else { return nil }
            let index = (y * buffer.width + x) * bytesPerPixel
            return (
                buffer.bytes[index],
                buffer.bytes[index + 1],
                buffer.bytes[index + 2],
                buffer.bytes[index + 3]
            )
        }

        for y in 0..<height {
            for x in 0..<width {
                let expectedPixel = pixel(expected, x, y)
                let actualPixel = pixel(actual, x, y)
                let same: Bool
                switch (expectedPixel, actualPixel) {
                case let (.some(e), .some(a)):
                    same = e.0 == a.0 && e.1 == a.1 && e.2 == a.2 && e.3 == a.3
                case (.none, .none):
                    same = true
                default:
                    same = false
                }

                let index = (y * width + x) * bytesPerPixel
                if same {
                    diff[index] = 0
                    diff[index + 1] = 0
                    diff[index + 2] = 0
                    diff[index + 3] = 0
                } else {
                    diff[index] = 255
                    diff[index + 1] = 0
                    diff[index + 2] = 0
                    diff[index + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(diff) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
