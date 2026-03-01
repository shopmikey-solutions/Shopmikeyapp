// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShopmikeyCoreNetworking",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ShopmikeyCoreNetworking", targets: ["ShopmikeyCoreNetworking"])
    ],
    dependencies: [
        .package(path: "../ShopmikeyCoreModels"),
        .package(path: "../ShopmikeyCoreDiagnostics")
    ],
    targets: [
        .target(
            name: "ShopmikeyCoreNetworking",
            dependencies: [
                "ShopmikeyCoreModels",
                "ShopmikeyCoreDiagnostics"
            ],
            path: "Sources/ShopmikeyCoreNetworking"
        )
    ]
)
