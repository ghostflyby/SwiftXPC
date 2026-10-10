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
    let watchdog = DispatchWorkItem { Foundation.exit(2) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
    defer { watchdog.cancel() }
    do {
      func argument(_ flag: String) throws -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
        guard CommandLine.arguments.indices.contains(index + 1),
          !CommandLine.arguments[index + 1].hasPrefix("--")
        else { throw NSError(domain: "MissingArgument", code: 1, userInfo: ["flag": flag]) }
        return CommandLine.arguments[index + 1]
      }
      // toService looks up the embedded .xpc bundle on either backend.
      let handle: XPCRootConnection<DemoRoot>
      let transport: XPCChannelTransport =
        CommandLine.arguments.contains("--session") ? .session : .cConnection
      if let name = try argument("--mach-service") {
        handle = try XPCRootConnection<DemoRoot>.connect(
          machService: name, transport: transport)
      } else {
        handle = try XPCRootConnection<DemoRoot>.connect(
          toService: try argument("--xpc-service") ?? demoServiceIdentifier, transport: transport)
      }
      defer { handle.close() }
      if CommandLine.arguments.contains("--expect-rejection") {
        do {
          _ = try await handle.root.configuration()
        } catch is XPCChannelError {
          print("service rejection observed")
          return
        }
        throw NSError(domain: "ExpectedServiceRejection", code: 1)
      }
      for await event in handle.events {
        print("connection event: \(event)")
        break
      }

      let configuration = try await handle.retrying { _ in try await handle.root.configuration() }
      guard configuration == "injected" else {
        throw NSError(domain: "UnpreparedRoot", code: 1)
      }
      print("root injection and preparation ok")

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
      if CommandLine.arguments.contains("--retire") {
        let reply = Task { try await handle.root.retire() }
        await handle.connection.waitForDisconnection()
        reply.cancel()
        print("cooperative retirement observed")
      }

    } catch {
      fputs("DistributedXPCDemo failed: \(error)\n", stderr)
      Foundation.exit(1)
    }
  }
}
