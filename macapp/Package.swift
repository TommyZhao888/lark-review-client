// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LarkReviewClient",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LarkReviewClient",
            path: "Sources/LarkReviewClient"
        ),
        .testTarget(
            name: "LarkReviewClientTests",
            dependencies: ["LarkReviewClient"],
            path: "Tests/LarkReviewClientTests"
        ),
    ]
)
