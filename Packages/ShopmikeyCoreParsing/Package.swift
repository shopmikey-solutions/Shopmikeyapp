// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShopmikeyCoreParsing",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ShopmikeyCoreParsing", targets: ["ShopmikeyCoreParsing"])
    ],
    dependencies: [
        .package(path: "../ShopmikeyCoreModels"),
        .package(path: "../ShopmikeyCoreDiagnostics")
    ],
    targets: [
        .target(
            name: "ShopmikeyCoreParsing",
            dependencies: [
                "ShopmikeyCoreModels",
                "ShopmikeyCoreDiagnostics"
            ],
            path: "Sources/ShopmikeyCoreParsing"
        )
    ]
)
