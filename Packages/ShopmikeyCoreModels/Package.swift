// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShopmikeyCoreModels",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ShopmikeyCoreModels", targets: ["ShopmikeyCoreModels"])
    ],
    targets: [
        .target(
            name: "ShopmikeyCoreModels",
            path: "Sources/ShopmikeyCoreModels"
        )
    ]
)
