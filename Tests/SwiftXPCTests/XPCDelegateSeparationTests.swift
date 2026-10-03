// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DistributedXPC
import Foundation
import SwiftXPC
import Synchronization
import Testing

struct XPCDelegateSeparationTests {
  @Test(arguments: XPCChannelTransport.allCases)
  func ActorServiceOwnsListenersThroughShutdown(transport: XPCChannelTransport) async throws {
    let service = XPCActorService(DelegateRoot.self, transport: transport)
    var listener: XPCChannelAcceptor? = try service.listen()
    weak var ownedListener = listener
    let endpoint = try #require(listener).wireEndpoint
    listener = nil
    #expect(ownedListener != nil)

    let client = try XPCRootConnection<DelegateRoot>.connect(
      using: transport.channel(dialing: endpoint))
    defer { client.close() }
    #expect(try await client.root.ping() == "delegate")

    service.host.requestShutdown()
    #expect(await service.host.waitForShutdown(timeout: .seconds(2)))
    #expect(ownedListener == nil)
    await client.connection.waitForDisconnection()
    #expect(throws: XPCChannelError.invalid) { try service.listen() }
  }

  @Test func SessionConformerUsesNativeAdmissionAndCommonLifecycle() async throws {
    final class Delegate: XPCSessionServiceDelegate {
      let events = Mutex<[String]>([])
      func shouldAcceptSessionRequest(_ request: XPCListener.IncomingSessionRequest) throws -> Bool
      {
        events.withLock { $0.append("admit") }
        return true
      }
      func didAcceptPeer(_ peer: XPCChannel) { events.withLock { $0.append("bound") } }
      func serviceWillShutdown() { events.withLock { $0.append("shutdown") } }
    }
    let delegate = Delegate()
    let service = try xpcTest(DelegateRoot.self, sessionDelegate: delegate)
    defer { service.close() }
    #expect(try await service.client.root.ping() == "delegate")
    #expect(delegate.events.withLock { $0 } == ["admit", "bound"])
    service.host.requestShutdown()
    #expect(delegate.events.withLock { $0 } == ["admit", "bound", "shutdown"])
  }
}
