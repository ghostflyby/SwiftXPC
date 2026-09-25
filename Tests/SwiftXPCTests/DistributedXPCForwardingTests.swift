// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import SwiftXPC
import SwiftXPCMacros
import Testing

@XPCService
distributed actor ForwardWorker {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func work(_ input: String) -> String {
    "worked: \(input)"
  }
}

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

@Test func ForwardedProxyRoundTripsThroughOwnerEndpoint() async throws {
  let channel = try RootChannel(ForwardRoot.self)
  defer { channel.close() }
  let root = try ForwardRoot.connect(using: channel.client)
  let worker = try await root.makeWorker()

  // The client-side proxy is sent back to the server and returned; each hop
  // re-emits the stored endpoint so the receiver dials the owner directly.
  let forwarded = try await root.forward(worker: worker)

  #expect(try await forwarded.work("forward") == "worked: forward")
  #expect(try await worker.work("original") == "worked: original")
}

@Test func SameProxyForwardedTwiceServesParallelPeers() async throws {
  let channel = try RootChannel(ForwardRoot.self)
  defer { channel.close() }
  let root = try ForwardRoot.connect(using: channel.client)
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
  let channel = try RootChannel(
    ForwardRoot.self, XPCServiceConfiguration(shouldAccept: { _ in false }))
  channel.client.setEventHandler { _ in }
  // The client side is the harness's already-active production channel;
  // the pre-activation contract under test is server-side (reject before
  // the peer is activated), so re-driving the client here is equivalent.
  channel.client.activate()
  defer { channel.close() }

  do {
    _ = try await channel.client.send(message: XPCWireDictionary())
    Issue.record("Expected rejected peer send to fail")
  } catch XPCConnection.ConnectionError.interrupted {
    // expected: the server cancels rejected peers, which the client observes
    // as interruption rather than service invalidation.
  } catch {
    Issue.record("Expected .interrupted, got \(error)")
  }
}
