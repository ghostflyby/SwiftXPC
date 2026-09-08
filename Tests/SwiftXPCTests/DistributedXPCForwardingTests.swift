// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import SwiftXPC
import SwiftXPCMacros
import Synchronization
import Testing
import XPC

@available(macOS 15, *)
@XPCService
distributed actor ForwardWorker {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func work(_ input: String) -> String {
    "worked: \(input)"
  }
}

@available(macOS 15, *)
@XPCService
distributed actor ForwardRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func makeWorker() -> ForwardWorker {
    ForwardWorker(actorSystem: actorSystem)
  }

  distributed func forward(worker: ForwardWorker) -> ForwardWorker {
    worker
  }
}

@available(macOS 15, *)
private final class ForwardChannelFixture: @unchecked Sendable {
  let listener: XPCConnection
  let client: XPCConnection
  let server: XPCRootActorServer<ForwardRoot>
  let watchdog: DispatchWorkItem

  init(listener: XPCConnection, client: XPCConnection, server: XPCRootActorServer<ForwardRoot>) {
    self.listener = listener
    self.client = client
    self.server = server
    watchdog = DispatchWorkItem {
      client.cancel()
      listener.cancel()
      server.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
  }

  deinit {
    watchdog.cancel()
    client.cancel()
    listener.cancel()
    server.cancel()
  }
}

@available(macOS 15, *)
private func makeForwardChannel() throws -> ForwardChannelFixture {
  let listener = XPCConnection(name: nil)
  let server = XPCRootActorServer(ForwardRoot.self)

  listener.setEventHandler { object in
    guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
    server.accept(XPCConnection(xpc_object: object.xpc_object))
  }
  listener.activate()

  let client = try XPCConnection.unmarshal(from: listener.marshal())
  return ForwardChannelFixture(listener: listener, client: client, server: server)
}

@Test func ForwardedProxyRoundTripsThroughOwnerEndpoint() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeForwardChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ForwardRoot.connect(using: fixture.client)
  let worker = try await root.makeWorker()

  // The client-side proxy is sent back to the server and returned; each hop
  // re-emits the stored endpoint so the receiver dials the owner directly.
  let forwarded = try await root.forward(worker: worker)

  #expect(try await forwarded.work("forward") == "worked: forward")
  #expect(try await worker.work("original") == "worked: original")
}

@Test func SameProxyForwardedTwiceServesParallelPeers() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeForwardChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ForwardRoot.connect(using: fixture.client)
  let worker = try await root.makeWorker()

  let first = try await root.forward(worker: worker)
  let second = try await root.forward(worker: worker)

  async let a: String = first.work("first")
  async let b: String = second.work("second")
  async let c: String = worker.work("original")
  let results = try await [a, b, c]
  #expect(
    Set(results) == [
      "worked: first",
      "worked: second",
      "worked: original",
    ])
}

@Test func RootServerRejectsPeerBeforeActivation() async throws {
  guard #available(macOS 15, *) else { return }
  let listener = XPCConnection(name: nil)
  let server = XPCRootActorServer(ForwardRoot.self, shouldAccept: { _ in false })
  listener.setEventHandler { object in
    guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
    server.accept(XPCConnection(xpc_object: object.xpc_object))
  }
  listener.activate()

  let client = try XPCConnection.unmarshal(from: listener.marshal())
  client.setEventHandler { _ in }
  client.activate()
  defer { client.cancel(); listener.cancel() }

  do {
    _ = try await client.send(message: XPCDictionary())
    Issue.record("Expected rejected peer send to fail")
  } catch XPCConnection.ConnectionError.interupted {
    // expected: the server cancels rejected peers, which the client observes
    // as interruption rather than service invalidation.
  } catch {
    Issue.record("Expected .interupted, got \(error)")
  }
}
