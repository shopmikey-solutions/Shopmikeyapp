// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShopmikeyCoreSync",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ShopmikeyCoreSync", targets: ["ShopmikeyCoreSync"])
    ],
    dependencies: [
        .package(path: "../ShopmikeyCoreModels"),
        .package(path: "../ShopmikeyCoreDiagnostics")
    ],
    targets: [
        .target(
            name: "ShopmikeyCoreSync",
            dependencies: [
                "ShopmikeyCoreModels",
                "ShopmikeyCoreDiagnostics"
            ],
            path: "Sources/ShopmikeyCoreSync"
        )
    ]
)
