// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShopmikeyCoreDiagnostics",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ShopmikeyCoreDiagnostics", targets: ["ShopmikeyCoreDiagnostics"])
    ],
    targets: [
        .target(
            name: "ShopmikeyCoreDiagnostics",
            path: "Sources/ShopmikeyCoreDiagnostics"
        )
    ]
)
