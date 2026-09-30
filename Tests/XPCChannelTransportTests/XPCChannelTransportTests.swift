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
/// channel, cancellation chains, wire endpoint typing, and the unified
/// service host (accept/echo, fail-closed requirements, shutdown pipeline).
///
/// Every scenario constructs the backend-specific acceptor through the
/// single factory `XPCChannelTransport.acceptor()` and stays typed against
/// the unified `XPCChannelAcceptor`.
@Suite(.serialized)
struct XPCChannelTransportTests {

  private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let semaphore = DispatchSemaphore(value: 0)

    func fire() {
      lock.lock()
      let first = !fired
      fired = true
      lock.unlock()
      if first { semaphore.signal() }
    }

    func wait(_ timeout: TimeInterval) -> Bool {
      semaphore.wait(timeout: .now() + timeout) == .success
    }
  }

  private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any Error)?
    private let semaphore = DispatchSemaphore(value: 0)

    func store(_ error: (any Error)?) {
      lock.lock()
      value = error
      lock.unlock()
      semaphore.signal()
    }

    func wait(_ timeout: TimeInterval) -> (any Error)? {
      guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

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

  // MARK: - Generic scenarios

  private func runRoundTrip(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try serverTransport.acceptor()
    let incoming = MessageBox()
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
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
    try acceptor.activate()

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

  private func runFireAndForget(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) throws {
    let acceptor = try serverTransport.acceptor()
    let incoming = MessageBox()
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
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
    try acceptor.activate()

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

  private func runPush(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try serverTransport.acceptor()
    let incoming = MessageBox()
    let pushedByClient = MessageBox()
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        incoming.store(message.payload)
      }
      channel.activate()
    }
    try acceptor.activate()

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
    let got = pushedByClient.wait(5)
    let pushedDecoded = got.map { XPCDictionary($0) }
    #expect(pushedDecoded != nil)
    #expect(pushedDecoded?["pushed"] == true)
    client.cancel()
    acceptor.cancel()
  }

  private func runCancelChain(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) throws {
    let invalidated = DispatchSemaphore(value: 0)
    let acceptor = try serverTransport.acceptor()
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.activate()
    }
    try acceptor.activate()

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

  private func runSendCancellation(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try serverTransport.acceptor()
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        // Reply late enough for the test to cancel the waiting task first.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
          var response = XPCDictionary()
          response["late"] = true
          message.reply(response.xpcObject)
        }
      }
      channel.activate()
    }
    try acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { _ in }
    client.activate()

    let sendTask = Task {
      var ask = XPCDictionary()
      ask["ask"] = "cancel-me"
      _ = try await client.send(ask.xpcObject, replyQueue: nil)
    }
    try await Task.sleep(for: .milliseconds(50))
    sendTask.cancel()
    do {
      _ = try await sendTask.value
      Issue.record("send must throw on task cancellation")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    // The late reply must be dropped harmlessly and the channel stays usable.
    try await Task.sleep(for: .milliseconds(400))
    var followUp = XPCDictionary()
    followUp["ask"] = "still-alive"
    let reply = try await client.send(followUp.xpcObject, replyQueue: nil)
    #expect(XPCDictionary(reply)["late"] == true)
    client.cancel()
    acceptor.cancel()
  }

  private func runPreActivationBuffering(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try serverTransport.acceptor()
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        var response = XPCDictionary()
        response["answered"] = true
        message.reply(response.xpcObject)
      }
      channel.activate()
    }
    try acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { _ in }
    // Both sends are issued BEFORE activation: they must buffer and issue
    // once activate() runs (libxpc does this natively on the C backend; the
    // session backend buffers in the channel).
    var wake = XPCDictionary()
    wake["wake"] = true
    client.sendAndForget(wake.xpcObject)
    var ask = XPCDictionary()
    ask["ask"] = "buffered"
    let replyTask = Task {
      SendableXPCObject(try await client.send(ask.xpcObject, replyQueue: nil))
    }
    try await Task.sleep(for: .milliseconds(50))
    client.activate()
    let reply = try await replyTask.value.raw
    #expect(XPCDictionary(reply)["answered"] == true)
    client.cancel()
    acceptor.cancel()
  }

  // MARK: - Parameterized entry points

  @Test(arguments: XPCBackendPair.all)
  func RoundTripThroughDeferredReplySink(pair: XPCBackendPair) async throws {
    try await runRoundTrip(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test(arguments: XPCBackendPair.all)
  func FireAndForgetDelivers(pair: XPCBackendPair) throws {
    try runFireAndForget(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test(arguments: XPCBackendPair.all)
  func PushReachesClientHandler(pair: XPCBackendPair) async throws {
    try await runPush(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test(arguments: XPCBackendPair.all)
  func CancelFiresTerminalChain(pair: XPCBackendPair) throws {
    try runCancelChain(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test(arguments: XPCBackendPair.all)
  func SendCancellationThrowsAndKeepsChannelUsable(pair: XPCBackendPair) async throws {
    try await runSendCancellation(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test(arguments: XPCBackendPair.all)
  func PreActivationSendsAreBuffered(pair: XPCBackendPair) async throws {
    try await runPreActivationBuffering(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test(arguments: XPCBackendPair.all)
  func WireEndpointIsEndpointObject(pair: XPCBackendPair) throws {
    let acceptor = try pair.server.acceptor()
    #expect(xpc_get_type(acceptor.wireEndpoint) == XPC_TYPE_ENDPOINT)
    acceptor.cancel()
  }

  // MARK: - Unified service host

  private func runUnifiedHostEcho(
    serverTransport: XPCChannelTransport,
    clientTransport: XPCChannelTransport
  ) async throws {
    let shutdown = FlagBox()
    let host = XPCServiceHost(XPCServiceConfiguration(onShutdown: { shutdown.fire() }))
    host.setPeerHandler { channel in
      channel.setIncomingHandler { message in
        var response = XPCDictionary()
        response["echo"] = XPCDictionary(message.payload)["ping", as: xpc_object_t.self]
        message.reply(response.xpcObject)
      }
    }

    let acceptor = try serverTransport.acceptor()
    acceptor.setAcceptHandler { channel in host.accept(channel) }
    try acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.activate()
    var ping = XPCDictionary()
    ping["ping"] = "host"
    let reply = try await client.send(ping.xpcObject, replyQueue: nil)
    #expect(XPCDictionary(reply)["echo"] == "host")

    // The cooperative shutdown pipeline runs the delegate hook and the
    // completion on both backends.
    host.requestShutdown()
    #expect(shutdown.wait(2))
    client.cancel()
    acceptor.cancel()
  }

  @Test(arguments: XPCBackendPair.all)
  func UnifiedHostAcceptsEchoesAndShutsDown(pair: XPCBackendPair) async throws {
    try await runUnifiedHostEcho(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test func RequirementFailsClosedOnSessionBackend() async throws {
    // A non-nil requirement on the session backend must reject the peer
    // with the install error (ENOTSUP) instead of silently hosting
    // unvalidated — the unified host's fail-closed path.
    let rejections = ErrorBox()
    let host = XPCServiceHost(
      XPCServiceConfiguration(
        peerCodeSigningRequirement: "identifier \"com.example.anything\"",
        onPeerReject: { _, error in rejections.store(error) }))

    let acceptor = try XPCChannelTransport.session.acceptor()
    acceptor.setAcceptHandler { channel in host.accept(channel) }
    try acceptor.activate()

    let client = try XPCChannelTransport.session.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { _ in }
    client.activate()
    var ping = XPCDictionary()
    ping["ping"] = true
    client.sendAndForget(ping.xpcObject)

    let rejection = rejections.wait(2)
    #expect(rejection != nil)
    #expect(rejection is XPCPeerRequirementError)
    client.cancel()
    acceptor.cancel()
  }
}
