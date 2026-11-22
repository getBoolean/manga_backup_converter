// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftSoupWrapper",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(
            name: "SwiftSoupWrapper",
            type: .dynamic,
            targets: ["SwiftSoupWrapper"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "SwiftSoupWrapper",
            dependencies: ["SwiftSoup"],
            path: "Sources"
        ),
    ]
)
