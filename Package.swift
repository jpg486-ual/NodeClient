// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NodeClientCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "NodeClientCore", targets: ["NodeClientCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "NodeClientCore",
            path: "NodeClient",
            exclude: [
                "Assets.xcassets",
                "ContentView.swift",
                "NodeClientApp.swift",
                "NodeClientRootView.swift",
                // Views/Files/ excluido del Core porque usa
                // UIKit (iOS-only). Refactor cross-platform diferido.
                "Views/Files"
            ],
            sources: [
                "Models",
                "Services",
                "Session",
                "ViewModels",
                "Views/Auth",
                "Views/Conflict",
                "Views/Favorites",
                "Views/More",
                "Views/Platform",
                "Views/Settings",
                "Views/Shared"
            ],
            resources: [
                // String catalog (Xcode 15+) ES + EN.
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "NodeClientCoreTests",
            dependencies: [
                "NodeClientCore"
            ],
            path: "NodeClientCoreTests",
            exclude: [
                "SnapshotTests/__Snapshots__"
            ]
        )
    ]
)
