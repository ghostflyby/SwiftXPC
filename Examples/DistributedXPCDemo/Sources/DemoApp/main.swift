// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import DistributedXPC
import DemoShared
import Foundation
import SwiftXPC

@main
struct DemoApp {
  static func main() async {
    guard #available(macOS 15, *) else {
      print("DistributedXPCDemo requires macOS 15 or newer.")
      return
    }

    let connection = XPCConnection(name: demoServiceIdentifier)
    let system = XPCDistributedActorSystem(connection: connection)
    connection.activate()

    do {
      let greeter = try DemoGreeter.resolve(id: XPCActorID(id: 1), using: system)

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
