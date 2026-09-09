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
      // XPCRootConnection survives engine restarts: `handle.root` rides a
      // named mach connection that launchd transparently re-establishes, so
      // root calls can be wrapped in `retrying` to ride out a restart.
      let handle = try XPCRootConnection<DemoRoot>.connect(toService: demoServiceIdentifier)
      defer { handle.close() }
      for await event in handle.events {
        print("connection event: \(event)")
        break
      }

      // Child actor references do NOT survive a service restart; re-acquire
      // them from the root inside `retrying` after (or during) a restart.
      let greeter = try await handle.retrying { _ in
        try await handle.root.makeGreeter()
      }

      print(try await greeter.greet(name: "SwiftXPC"))
      try await greeter.ping()
      print("ping ok")

      do {
        _ = try await greeter.greet(name: "error")
      } catch {
        print("received expected error: \(error)")
      }
      // Out-of-package @XPCMarshal round trip (compile + runtime check).
      let payload = DemoPayload(title: "smoke", count: 42)
      let decoded = try DemoPayload.unmarshal(from: try payload.marshal())
      print("payload round trip ok: \(decoded)")

    } catch {
      fputs("DistributedXPCDemo failed: \(error)\n", stderr)
      Foundation.exit(1)
    }
  }
}
