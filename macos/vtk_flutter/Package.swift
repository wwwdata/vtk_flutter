// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "vtk_flutter",
    platforms: [
        .macOS("11.0"),
    ],
    products: [
        .library(name: "vtk-flutter", targets: ["vtk_flutter"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "vtk_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/vtk_flutter"),
            ],
            cxxSettings: [
                .headerSearchPath("include/vtk_flutter"),
            ],
            linkerSettings: [
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
    ]
)
