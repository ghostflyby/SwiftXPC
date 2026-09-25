// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import Foundation
import PackageDescription

// Keep `-warnings-as-errors` opt-in: xcodebuild's package integration injects
// `-suppress-warnings` into remote dependency targets, and swiftc rejects the
// combination with "Conflicting options" (swiftlang/swift-package-manager#10192).
let warningsAsErrors =
  ProcessInfo.processInfo.environment["SWIFTXPC_WARNINGS_AS_ERRORS"].map {
    $0 == "1" || $0.lowercased() == "true"
  } ?? false
let warningSettings: [SwiftSetting] =
  warningsAsErrors ? [.treatAllWarnings(as: .error)] : []

let package = Package(
  name: "SwiftXPC",
  platforms: [.macOS(.v15)],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "SwiftXPC",
      targets: ["SwiftXPC"]
    ),
    .library(
      name: "DistributedXPC",
      targets: ["DistributedXPC"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-syntax.git", from: "603.0.2")
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "SwiftXPC",
      dependencies: [
        "SwiftXPCMacros"
      ],
      swiftSettings: warningSettings
    ),
    .macro(
      name: "SwiftXPCMacros",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "DistributedXPC",
      dependencies: ["SwiftXPC"],
      swiftSettings: warningSettings
    ),
    .testTarget(
      name: "SwiftXPCTests",
      dependencies: ["SwiftXPC", "DistributedXPC", "SwiftXPCMacros"]
    ),
  ]
)
