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
    let watchdog = DispatchWorkItem { service.cancel() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); service.cancel() }
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
    let service = try xpcTest(
      DelegateRoot.self, sessionDelegate: delegate, watchdog: .seconds(10))
    defer { service.close() }
    #expect(try await service.client.root.ping() == "delegate")
    #expect(delegate.events.withLock { $0 } == ["admit", "bound"])
    service.host.requestShutdown()
    #expect(delegate.events.withLock { $0 } == ["admit", "bound", "shutdown"])
  }
  @Test(arguments: XPCChannelTransport.allCases)
  func RuntimeBackendReceivesShutdownCompletion(transport: XPCChannelTransport)
    async throws
  {
    let completions = Mutex(0)
    let service = try xpcTest(
      DelegateRoot.self, transport: transport, watchdog: .seconds(10),
      onShutdown: { completions.withLock { $0 += 1 } })
    defer { service.close() }
    #expect(try await service.client.root.ping() == "delegate")
    service.host.requestShutdown()
    #expect(await service.host.waitForShutdown(timeout: .seconds(2)))
    #expect(completions.withLock { $0 } == 1)
  }

  @Test func SessionShutdownCompletionFollowsDelegateHook() async throws {
    let events = Mutex<[String]>([])
    let service = try xpcTest(
      DelegateRoot.self,
      sessionDelegate: XPCSessionServiceConfiguration(onShutdown: {
        events.withLock { $0.append("delegate") }
      }), watchdog: .seconds(10), onShutdown: { events.withLock { $0.append("completion") } })
    defer { service.close() }
    service.host.requestShutdown()
    #expect(events.withLock { $0 } == ["delegate", "completion"])
  }

}
