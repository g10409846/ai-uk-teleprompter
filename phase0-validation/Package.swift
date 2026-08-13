// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUKTeleprompter",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Phase0Validator", targets: ["Phase0Validator"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TeleprompterCore",
            dependencies: [],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "Phase0Validator",
            dependencies: ["TeleprompterCore"],
            path: "Sources/Phase0Validator"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["TeleprompterCore"],
            path: "Tests/CoreTests"
        )
    ]
)
