import SwiftUI
import UIKit
import XCTest

@MainActor
enum SnapshotTestSupport {
    struct SnapshotConfig {
        let size: CGSize
        let scale: CGFloat
        let interfaceStyle: UIUserInterfaceStyle
        let dynamicTypeSize: DynamicTypeSize
        let dynamicTypeLabel: String

        static let lightDefault = SnapshotConfig(
            size: CGSize(width: 393, height: 852),
            scale: 3,
            interfaceStyle: .light,
            dynamicTypeSize: .large,
            dynamicTypeLabel: "L"
        )

        static let darkDefault = SnapshotConfig(
            size: CGSize(width: 393, height: 852),
            scale: 3,
            interfaceStyle: .dark,
            dynamicTypeSize: .large,
            dynamicTypeLabel: "L"
        )

        static let lightXXXL = SnapshotConfig(
            size: CGSize(width: 393, height: 852),
            scale: 3,
            interfaceStyle: .light,
            dynamicTypeSize: .xxxLarge,
            dynamicTypeLabel: "XXXL"
        )
    }

    static func render<V: View>(view: V, config: SnapshotConfig) -> UIImage {
        let rootView = view
            .environment(\.colorScheme, config.interfaceStyle == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, config.dynamicTypeSize)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .current)
            .environment(\.calendar, Calendar(identifier: .gregorian))

        let host = UIHostingController(rootView: rootView)
        host.view.frame = CGRect(origin: .zero, size: config.size)
        host.view.backgroundColor = .systemBackground

        let window = UIWindow(frame: CGRect(origin: .zero, size: config.size))
        window.overrideUserInterfaceStyle = config.interfaceStyle
        window.rootViewController = host
        window.makeKeyAndVisible()

        let previousAnimationState = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(previousAnimationState)
            window.isHidden = true
            window.rootViewController = nil
        }

        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        host.view.tintColor = .systemBlue
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = config.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: config.size, format: format)
        return renderer.image { _ in
            guard let context = UIGraphicsGetCurrentContext() else { return }
            host.view.layer.render(in: context)
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
