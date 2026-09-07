// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "flutter_background_location_tracker",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(
      name: "flutter-background-location-tracker",
      targets: ["flutter_background_location_tracker"]
    )
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "flutter_background_location_tracker",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      resources: [
        .process("PrivacyInfo.xcprivacy")
      ],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .testTarget(
      name: "flutter_background_location_trackerTests",
      dependencies: ["flutter_background_location_tracker"]
    )
  ]
)
