// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FreeReading",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FreeReadingCore", targets: ["FreeReadingCore"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.4")
    ],
    targets: [
        .target(name: "FreeReadingCore", dependencies: ["ZIPFoundation", "SwiftSoup"]),
        .testTarget(name: "FreeReadingCoreTests", dependencies: ["FreeReadingCore", "ZIPFoundation"], resources: [.copy("Fixtures")])
    ]
)
