// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftXPC
import Synchronization

@main
struct XPCPeerRequirementProbe {
  static func main() async throws {
    guard #available(macOS 26.0, *) else { return }
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else { throw ProbeError.invalidArguments }
    switch arguments[1] {
    case "serve":
      guard arguments.count == 4 else { throw ProbeError.invalidArguments }
      try await serve(service: arguments[2], entitlement: arguments[3])
    case "allow", "deny":
      try await call(service: arguments[2], allowed: arguments[1] == "allow")
    default: throw ProbeError.invalidArguments
    }
  }

  enum ProbeError: Error { case invalidArguments, unexpectedReply, unexpectedAdmission, timeout }

  @available(macOS 26.0, *)
  private static func serve(service: String, entitlement: String) async throws {
    struct Counts { var audits = 0; var rejections = 0; var deliveries = 0 }
    let counts = Mutex(Counts())
    let peers = Mutex<[XPCChannel]>([])
    let delegate = XPCSessionServiceConfiguration(
      shouldAccept: { _ in
        counts.withLock { $0.audits += 1 }; return true
      },
      onSessionReject: { _, _ in counts.withLock { $0.rejections += 1 } })
    let listener = try XPCChannelAcceptor(
      sessionDelegate: delegate, service: service, requirement: .hasEntitlement(entitlement)
    ) { peer in
      counts.withLock { $0.deliveries += 1 }
      peers.withLock { $0.append(peer) }
      peer.setIncomingHandler { message in
        let snapshot = counts.withLock { $0 }
        var reply = XPCDictionary()
        reply["audits"] = snapshot.audits
        reply["rejections"] = snapshot.rejections
        reply["deliveries"] = snapshot.deliveries
        message.reply(reply.xpcObject)
      }
      peer.activate()
    }
    defer {
      listener.cancel()
      peers.withLock { $0 }.forEach { $0.cancel() }
    }
    try listener.activate()
    // Bound the fixture even if the parent dies before unloading its job.
    try await Task.sleep(for: .seconds(60))
    throw ProbeError.timeout
  }

  private static func call(service: String, allowed: Bool) async throws {
    let channel = XPCChannelTransport.session.channel(machService: service)
    // Timeout must fail the fixture, not masquerade as a rejected peer.
    let watchdog = DispatchWorkItem { exit(2) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); channel.cancel() }
    channel.activate()
    do {
      let reply = try await channel.send(XPCDictionary().xpcObject)
      guard allowed else { throw ProbeError.unexpectedAdmission }
      let dictionary = XPCDictionary(reply)
      guard let audits = dictionary["audits", as: Int.self],
        let deliveries = dictionary["deliveries", as: Int.self],
        let rejections = dictionary["rejections", as: Int.self]
      else { throw ProbeError.unexpectedReply }
      print("\(audits),\(deliveries),\(rejections)")
    } catch XPCChannelError.invalid where !allowed {
      // A dropped Session cannot be reused or retried.
      print("denied")
    }
  }
}
