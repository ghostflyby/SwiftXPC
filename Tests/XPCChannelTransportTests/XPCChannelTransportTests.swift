// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Synchronization
import SwiftXPC
import Testing

/// One (server acceptor, client dial) backend combination. Every transport
/// scenario runs over all four combinations, which also exercises
/// mixed-backend interop — endpoints are `XPC_TYPE_ENDPOINT` objects and can
/// be dialed by either backend.
struct XPCBackendPair: CustomStringConvertible, Sendable {
  let server: XPCChannelTransport
  let client: XPCChannelTransport

  static let all: [XPCBackendPair] = [
    .init(server: .cConnection, client: .cConnection),
    .init(server: .cConnection, client: .session),
    .init(server: .session, client: .cConnection),
    .init(server: .session, client: .session),
  ]

  var description: String { "server=\(server) client=\(client)" }
}

/// Transport scenarios for every backend combination: round trip through the
/// reply sink, fire-and-forget delivery, server pushes over the accepted
/// channel, cancellation chains, and wire endpoint typing.
///
/// The listener level is intentionally *not* unified behind a protocol: the
/// C acceptor is a connection wrapper (its listener is a `xpc_connection_t`
/// usage and mints endpoints itself), the session acceptor directly wraps
/// `XPCListener` (whose endpoint lives on the overlay side). Each scenario
/// therefore constructs the concrete acceptor through one switch seam and
/// runs as a generic function over `XPCChannelAcceptor`.
@Suite(.serialized)
struct XPCChannelTransportTests {

  private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [xpc_object_t] = []
    private let semaphore = DispatchSemaphore(value: 0)

    func store(_ payload: xpc_object_t) {
      lock.lock()
      values.append(payload)
      lock.unlock()
      semaphore.signal()
    }

    func wait(_ timeout: TimeInterval) -> xpc_object_t? {
      guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return values.last
    }
  }

  private func makeAcceptor(
    for transport: XPCChannelTransport
  ) throws -> any XPCChannelAcceptor {
    switch transport {
    case .cConnection: return XPCConnectionAcceptor()
    case .session: return try XPCListenerAcceptor()
    }
  }

  // MARK: - Generic scenarios

  private func runRoundTrip<A: XPCChannelAcceptor>(
    makeAcceptor: @escaping () throws -> A,
    clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try makeAcceptor()
    let incoming = MessageBox()
    acceptor.setAcceptHandler { channel in
      channel.setIncomingHandler { message in
        incoming.store(message.payload)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
          var response = XPCDictionary()
          response["answered"] = true
          message.reply(response.xpcObject)
        }
      }
      channel.activate()
    }
    acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.activate()
    var request = XPCDictionary()
    request["ask"] = "roundtrip"
    let reply = try await client.send(request.xpcObject, replyQueue: nil)
    #expect(XPCDictionary(reply)["answered"] == true)
    #expect(incoming.wait(5) != nil)
    client.cancel()
    acceptor.cancel()
  }

  private func runFireAndForget<A: XPCChannelAcceptor>(
    makeAcceptor: @escaping () throws -> A,
    clientTransport: XPCChannelTransport
  ) throws {
    let acceptor = try makeAcceptor()
    let incoming = MessageBox()
    acceptor.setAcceptHandler { channel in
      channel.setIncomingHandler { message in
        incoming.store(message.payload)
        // Replying to a fire-and-forget message is dropped by the transport
        // (the C backend's create_reply returns nil for it; the session
        // backend consumes it silently).
        var response = XPCDictionary()
        response["answer"] = true
        message.reply(response.xpcObject)
      }
      channel.activate()
    }
    acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.activate()
    var request = XPCDictionary()
    request["forget"] = true
    client.sendAndForget(request.xpcObject)

    let received = incoming.wait(5)
    #expect(received != nil)
    let decoded = received.map { XPCDictionary($0) }
    #expect(decoded?["forget"] == true)
    client.cancel()
    acceptor.cancel()
  }

  private func runPush<A: XPCChannelAcceptor>(
    makeAcceptor: @escaping () throws -> A,
    clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try makeAcceptor()
    let incoming = MessageBox()
    let pushed = MessageBox()
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        incoming.store(message.payload)
      }
      channel.activate()
    }
    acceptor.activate()

    let pushedByClient = MessageBox()
    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { message in
      pushedByClient.store(message.payload)
    }
    client.activate()
    var request = XPCDictionary()
    request["register"] = true
    client.sendAndForget(request.xpcObject)
    #expect(incoming.wait(5) != nil)

    // The server pushes over the accepted channel. Retaining it matters:
    // a delivered channel owns its session (dropping it cancels).
    guard let serverChannel = retained.withLock({ $0 }) else {
      Issue.record("accepted channel was dropped before the push")
      return
    }
    var push = XPCDictionary()
    push["pushed"] = true
    serverChannel.sendAndForget(push.xpcObject)
    let got = pushed.wait(5)
    #expect(got != nil)
    #expect(XPCDictionary(got!)["pushed"] == true)
    client.cancel()
    acceptor.cancel()
  }

  private func runCancelChain<A: XPCChannelAcceptor>(
    makeAcceptor: @escaping () throws -> A,
    clientTransport: XPCChannelTransport
  ) throws {
    let invalidated = DispatchSemaphore(value: 0)
    let acceptor = try makeAcceptor()
    acceptor.setAcceptHandler { channel in
      channel.activate()
    }
    acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { _ in }
    // Manual cancel is terminal: route to the invalidation chain.
    client.addInvalidationHandler { invalidated.signal() }
    client.addInterruptionHandler {
      Issue.record("interruption chain must not fire on cancel")
    }
    client.activate()

    var wake = XPCDictionary()
    wake["wake"] = true
    client.sendAndForget(wake.xpcObject)
    // Let the listener deliver and activate the peer before cancelling.
    Thread.sleep(forTimeInterval: 0.15)
    client.cancel()

    #expect(invalidated.wait(timeout: DispatchTime.now() + 5) == .success)
    acceptor.cancel()
  }

  // MARK: - Parameterized entry points

  @Test(arguments: XPCBackendPair.all)
  func RoundTripThroughDeferredReplySink(pair: XPCBackendPair) async throws {
    switch pair.server {
    case .cConnection:
      try await runRoundTrip(
        makeAcceptor: XPCConnectionAcceptor.init, clientTransport: pair.client)
    case .session:
      try await runRoundTrip(
        makeAcceptor: XPCListenerAcceptor.init, clientTransport: pair.client)
    }
  }

  @Test(arguments: XPCBackendPair.all)
  func FireAndForgetDelivers(pair: XPCBackendPair) throws {
    switch pair.server {
    case .cConnection:
      try runFireAndForget(
        makeAcceptor: XPCConnectionAcceptor.init, clientTransport: pair.client)
    case .session:
      try runFireAndForget(
        makeAcceptor: XPCListenerAcceptor.init, clientTransport: pair.client)
    }
  }

  @Test(arguments: XPCBackendPair.all)
  func PushReachesClientHandler(pair: XPCBackendPair) async throws {
    switch pair.server {
    case .cConnection:
      try await runPush(
        makeAcceptor: XPCConnectionAcceptor.init, clientTransport: pair.client)
    case .session:
      try await runPush(
        makeAcceptor: XPCListenerAcceptor.init, clientTransport: pair.client)
    }
  }

  @Test(arguments: XPCBackendPair.all)
  func CancelFiresTerminalChain(pair: XPCBackendPair) throws {
    switch pair.server {
    case .cConnection:
      try runCancelChain(makeAcceptor: XPCConnectionAcceptor.init, clientTransport: pair.client)
    case .session:
      try runCancelChain(makeAcceptor: XPCListenerAcceptor.init, clientTransport: pair.client)
    }
  }

  @Test(arguments: XPCBackendPair.all)
  func WireEndpointIsEndpointObject(pair: XPCBackendPair) throws {
    let acceptor = try makeAcceptor(for: pair.server)
    #expect(xpc_get_type(acceptor.wireEndpoint) == XPC_TYPE_ENDPOINT)
    acceptor.cancel()
  }
}
