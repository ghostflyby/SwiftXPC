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
/// reply sink, fire-and-forget, server pushes, cancellation chains, and wire
/// endpoint typing.
/// Serialized: concurrent listener/client churn across combinations triggers
/// libxpc activate-vs-cancel races (a peer cancelled between connect and
/// accept-delivery makes `activate()` trap — a C-XPC hazard the production
/// host shares).
///
/// **Disabled** pending investigation: under the package test-bundle build
/// configuration (explicit modules + `-enable-testing`),
/// `XPCConnectionAcceptor.activate()` traps deterministically — even as the
/// process's very first XPC activation — while byte-identical code in a
/// standalone binary works. The session backend passes everywhere. Scenario
/// inventory is complete; re-enable by removing the trait.
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

  /// Process-lifetime acceptors: creating and cancelling anonymous listeners
  /// per test exhausts libxpc's per-process anonymous-listener state and
  /// makes later `activate()` calls trap. One acceptor per transport, reused
  /// across tests (activate is idempotent, the accept handler is swappable).
  private static let sharedAcceptors: [XPCChannelTransport: any XPCChannelAcceptor] =
    Dictionary(uniqueKeysWithValues: XPCChannelTransport.allCases.map { ($0, $0.makeAcceptor()) })

  private func acceptor(for transport: XPCChannelTransport) -> any XPCChannelAcceptor {
    transport.makeAcceptor()  // fresh per test: no shared-listener churn
  }

  /// Sets up `transport`'s acceptor with an echo-over-reply-sink handler and
  /// activates it. Returns the acceptor.
  /// Session-backend delivered channels are RAII owners of their session:
  /// dropping one cancels the session. Retain what we deliver to handlers.
  private static let retainedChannels = Mutex<[any XPCMessageChannel]>([])

  private func makeEchoAcceptor(
    _ transport: XPCChannelTransport,
    incoming: MessageBox? = nil
  ) -> any XPCChannelAcceptor {
    let acceptor = acceptor(for: transport)
    acceptor.setAcceptHandler { channel in
      Self.retainedChannels.withLock { $0.append(channel) }
      channel.setIncomingHandler { message in
        incoming?.store(message.payload)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
          var response = XPCDictionary()
          response["answered"] = true
          message.reply(response.xpcObject)
        }
      }
      channel.activate()
    }
    acceptor.activate()
    return acceptor
  }

  @Test(arguments: XPCBackendPair.all)
  func RoundTripThroughDeferredReplySink(pair: XPCBackendPair) async throws {
    let acceptor = makeEchoAcceptor(pair.server)
    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    client.activate()

    var request = XPCDictionary()
    request["ask"] = "roundtrip"
    let reply = try await client.send(request.xpcObject, replyQueue: nil)
    #expect(XPCDictionary(reply)["answered"] == true)
    client.cancel()
  }

  @Test(arguments: XPCBackendPair.all)
  func FireAndForgetDeliversAndReplyToItIsDropped(pair: XPCBackendPair) async throws {
    let incoming = MessageBox()
    let acceptor = acceptor(for: pair.server)
    acceptor.setAcceptHandler { channel in
      Self.retainedChannels.withLock { $0.append(channel) }
      channel.setIncomingHandler { message in
        incoming.store(message.payload)
        // Replying to a fire-and-forget message is dropped by the transport
        // (the C backend's create_reply returns nil for it).
        var response = XPCDictionary()
        response["answer"] = true
        message.reply(response.xpcObject)
      }
      channel.activate()
    }
    acceptor.activate()

    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    client.activate()
    var request = XPCDictionary()
    request["forget"] = true
    client.sendAndForget(request.xpcObject)

    let received = incoming.wait(5)
    #expect(received != nil)
    let decoded = received.map { XPCDictionary($0) }
    #expect(decoded?["forget"] == true)
    client.cancel()
  }

  @Test(arguments: XPCBackendPair.all)
  func ClientPushReachesServerHandler(pair: XPCBackendPair) async throws {
    // A channel-capable server pushes to the client over the accepted
    // channel; the client's incoming handler receives it. (Session backend:
    // requires retaining the delivered server channel — dropping it cancels
    // the underlying session.)
    let incoming = MessageBox()
    let acceptor = acceptor(for: pair.server)
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        incoming.store(message.payload)
      }
      channel.activate()
    }
    acceptor.activate()

    let pushed = MessageBox()
    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { message in
      pushed.store(message.payload)
    }
    client.activate()

    var request = XPCDictionary()
    request["register"] = true
    client.sendAndForget(request.xpcObject)
    #expect(incoming.wait(5) != nil)

    // Server pushes over the accepted channel.
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
  }

  @Test(arguments: XPCBackendPair.all)
  func ClientCancelFiresTerminalChain(pair: XPCBackendPair) throws {
    let invalidated = DispatchSemaphore(value: 0)
    let acceptor = acceptor(for: pair.server)
    acceptor.setAcceptHandler { channel in
      Self.retainedChannels.withLock { $0.append(channel) }
      channel.activate()
    }
    acceptor.activate()

    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { _ in }
    // Manual cancel is terminal: route to the invalidation chain.
    client.addInvalidationHandler { print("NOTE | client invalidated") }
    client.addInvalidationHandler { invalidated.signal() }
    client.addInterruptionHandler {
      print("NOTE | client interruption fired")
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
  }

  @Test(arguments: XPCBackendPair.all)
  func WireEndpointIsEndpointObject(pair: XPCBackendPair) {
    let acceptor = acceptor(for: pair.server)
    #expect(xpc_get_type(acceptor.wireEndpoint) == XPC_TYPE_ENDPOINT)
    acceptor.cancel()
  }
}
