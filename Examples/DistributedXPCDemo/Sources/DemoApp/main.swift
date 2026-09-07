import DemoShared
// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import DistributedXPC
import Foundation
import SwiftXPC

@main
struct DemoApp {
  static func main() async {
    guard #available(macOS 15, *) else {
      print("DistributedXPCDemo requires macOS 15 or newer.")
      return
    }

    do {
      let root = try DemoRoot.connect(toService: demoServiceIdentifier)
      defer { withExtendedLifetime(root) {} }
      let greeter = try await root.makeGreeter()

      print(try await greeter.greet(name: "SwiftXPC"))
      try await greeter.ping()
      print("ping ok")

      do {
        _ = try await greeter.greet(name: "error")
      } catch {
        print("received expected error: \(error)")
      }
    } catch {
      fputs("DistributedXPCDemo failed: \(error)\n", stderr)
      Foundation.exit(1)
    }
  }
}
