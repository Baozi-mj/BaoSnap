// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BaoSnap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BaoSnap",
            path: "Sources/BaoSnap",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "BaoSnapTests",
            dependencies: ["BaoSnap"],
            path: "Tests/BaoSnapTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
