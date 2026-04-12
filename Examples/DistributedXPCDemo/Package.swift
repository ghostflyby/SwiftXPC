// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "DistributedXPCDemo",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "DemoApp", targets: ["DemoApp"]),
    .executable(name: "DemoService", targets: ["DemoService"]),
  ],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .target(
      name: "DemoShared",
      dependencies: [
        .product(name: "DistributedXPC", package: "SwiftXPC"),
        .product(name: "SwiftXPC", package: "SwiftXPC"),
      ]
    ),
    .executableTarget(
      name: "DemoApp",
      dependencies: [
        "DemoShared",
        .product(name: "DistributedXPC", package: "SwiftXPC"),
        .product(name: "SwiftXPC", package: "SwiftXPC"),
      ]
    ),
    .executableTarget(
      name: "DemoService",
      dependencies: [
        "DemoShared",
        .product(name: "DistributedXPC", package: "SwiftXPC"),
        .product(name: "SwiftXPC", package: "SwiftXPC"),
      ]
    ),
  ]
)
