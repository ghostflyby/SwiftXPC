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
    let retained = Mutex<(XPCChannel)?>(nil)
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
    let reply = try await client.send(request.xpcObject)
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
    let retained = Mutex<(XPCChannel)?>(nil)
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
    let retained = Mutex<(XPCChannel)?>(nil)
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
    let delivered = DispatchSemaphore(value: 0)
    let invalidated = DispatchSemaphore(value: 0)
    let acceptor = try serverTransport.acceptor()
    let retained = Mutex<(XPCChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.activate()
      delivered.signal()
    }
    try acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { _ in }
    // Manual cancel is terminal: route to the invalidation chain.
    client.addInvalidationHandler { invalidated.signal() }
    client.connection?.addInterruptionHandler {
      Issue.record("interruption chain must not fire on cancel")
    }
    client.activate()

    var wake = XPCDictionary()
    wake["wake"] = true
    client.sendAndForget(wake.xpcObject)
    // Let the listener deliver and activate the peer before cancelling.
    #expect(delivered.wait(timeout: .now() + 5) == .success)
    client.cancel()

    #expect(invalidated.wait(timeout: DispatchTime.now() + 5) == .success)
    acceptor.cancel()
  }

  private func runSendCancellation(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try serverTransport.acceptor()
    let retained = Mutex<(XPCChannel)?>(nil)
    let pendingReply = Mutex<XPCIncomingMessage?>(nil)
    let received = FlagBox()
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        if XPCDictionary(message.payload)["ask"] == "cancel-me" {
          pendingReply.withLock { $0 = message }
          received.fire()
        } else {
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
      _ = try await client.send(ask.xpcObject)
    }
    let delivered = await withCheckedContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(returning: received.wait(5)) }
    }
    #expect(delivered)
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
    let late = try #require(
      pendingReply.withLock { message in
        let saved = message
        message = nil
        return saved
      })
    late.reply(XPCDictionary().xpcObject)
    var followUp = XPCDictionary()
    followUp["ask"] = "still-alive"
    let reply = try await client.send(followUp.xpcObject)
    #expect(XPCDictionary(reply)["late"] == true)
    client.cancel()
    acceptor.cancel()
  }

  private func runPreActivationBuffering(
    serverTransport: XPCChannelTransport, clientTransport: XPCChannelTransport
  ) async throws {
    let acceptor = try serverTransport.acceptor()
    let retained = Mutex<(XPCChannel)?>(nil)
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
      SendableXPCObject(try await client.send(ask.xpcObject))
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

  @Test(arguments: XPCBackendPair.all)
  func CancelBeforeActivationFinishesBufferedSendAndDisconnection(pair: XPCBackendPair) async throws
  {
    let acceptor = try pair.server.acceptor()
    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    let send = Task { SendableXPCObject(try await client.send(XPCDictionary().xpcObject)) }
    try await Task.sleep(for: .milliseconds(20))
    client.cancel()
    await client.waitForDisconnection()
    await #expect(throws: XPCChannelError.self) { _ = try await send.value }
    // Cancelling an inactive listener must release it safely, without leaks.
    acceptor.cancel()
  }

  @Test(arguments: XPCBackendPair.all)
  func BackendSelectsNativeConnectionInterop(pair: XPCBackendPair) throws {
    let acceptor = try pair.server.acceptor()
    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    #expect(client.transport == pair.client)
    #expect((client.connection != nil) == (pair.client == .cConnection))
    client.cancel()
    acceptor.cancel()
  }

  @Test(arguments: XPCBackendPair.all)
  func AcceptedTrafficWaitsForActivationAndPreservesFIFO(pair: XPCBackendPair) async throws {
    let acceptor = try pair.server.acceptor()
    let accepted = FlagBox()
    let retained = Mutex<XPCChannel?>(nil)
    let received = Mutex<[Int64]>([])
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      accepted.fire()
    }
    try acceptor.activate()
    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    defer { client.cancel(); retained.withLock { $0 }?.cancel(); acceptor.cancel() }
    client.activate()
    for sequence in 0..<64 {
      let payload = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_int64(payload, "sequence", Int64(sequence))
      client.sendAndForget(payload)
    }
    #expect(accepted.wait(3))
    let server = try #require(retained.withLock { $0 })
    server.setIncomingHandler { message in
      let sequence = xpc_dictionary_get_int64(message.payload, "sequence")
      received.withLock { $0.append(sequence) }
      if sequence == 64 { message.reply(XPCDictionary().xpcObject) }
    }
    // Even a natively live Session peer must wait for logical admission.
    #expect(received.withLock { $0.isEmpty })
    server.activate()
    let last = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_int64(last, "sequence", 64)
    _ = try await client.send(last)
    #expect(received.withLock { $0 } == Array(Int64(0)...64))
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ConcurrentAcceptorActivationAndCancellationStayTerminal(transport: XPCChannelTransport)
    async throws
  {
    let acceptor = try transport.acceptor()
    let endpoint = acceptor.wireEndpoint
    let accepted = Mutex(0)
    acceptor.setAcceptHandler { channel in
      accepted.withLock { $0 += 1 }
      channel.cancel()
    }
    DispatchQueue.concurrentPerform(iterations: 64) { iteration in
      if iteration.isMultiple(of: 2) {
        do { try acceptor.activate() } catch XPCChannelAcceptor.ActivationError.inProgress {
          // A concurrent owner has not finished native activation yet.
        } catch {
          Issue.record("Unexpected anonymous listener activation failure: \(error)")
        }
      } else {
        acceptor.cancel()
      }
    }
    // Cancellation wins permanently, including against subsequent activation.
    try acceptor.activate()
    let client = try transport.channel(dialing: endpoint)
    defer { client.cancel(); acceptor.cancel() }
    client.activate()
    let send = Task { SendableXPCObject(try await client.send(XPCDictionary().xpcObject)) }
    let timeout = Task {
      try await Task.sleep(for: .seconds(3))
      send.cancel()
    }
    defer { timeout.cancel() }
    await #expect {
      _ = try await send.value
    } throws: { $0 is XPCChannelError || $0 is CancellationError }
    #expect(accepted.withLock { $0 } == 0)
  }

  // MARK: - Unified service host

  private func runUnifiedHostEcho(
    serverTransport: XPCChannelTransport,
    clientTransport: XPCChannelTransport
  ) async throws {
    let shutdown = FlagBox()
    let ended = FlagBox()
    let completed = FlagBox()
    let host = XPCServiceHost(
      XPCConnectionServiceConfiguration(
        onPeerEnd: { peer in
          #expect(peer.connection?.pid == (serverTransport == .cConnection ? getpid() : nil))
          #expect(peer.connection?.euid == (serverTransport == .cConnection ? geteuid() : nil))
          #expect(peer.connection?.egid == (serverTransport == .cConnection ? getegid() : nil))
          ended.fire()
        },
        onShutdown: { shutdown.fire() }),
      peerHandler: { channel in
        channel.setIncomingHandler { message in
          var response = XPCDictionary()
          response["echo"] = XPCDictionary(message.payload)["ping", as: xpc_object_t.self]
          message.reply(response.xpcObject)
        }
      }, onShutdown: { completed.fire() })

    let acceptor = try serverTransport.acceptor()
    acceptor.setAcceptHandler { channel in host.bind(channel) }
    try acceptor.activate()

    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.activate()
    var ping = XPCDictionary()
    ping["ping"] = "host"
    let reply = try await client.send(ping.xpcObject)
    #expect(XPCDictionary(reply)["echo"] == "host")

    // The cooperative shutdown pipeline runs the delegate hook and the
    // completion on both backends.
    host.requestShutdown()
    #expect(shutdown.wait(2))
    #expect(completed.wait(2))
    #expect(ended.wait(2))
    client.cancel()
    acceptor.cancel()
  }

  @Test(arguments: XPCBackendPair.all)
  func UnifiedHostAcceptsEchoesAndShutsDown(pair: XPCBackendPair) async throws {
    try await runUnifiedHostEcho(serverTransport: pair.server, clientTransport: pair.client)
  }

  @Test(arguments: XPCBackendPair.all)
  func BackendAdmissionFinishesBeforeBindingAndMessages(pair: XPCBackendPair) async throws {
    let events = Mutex<[String]>([])
    let log = XPCServiceEventLog()
    let binding: @Sendable (XPCChannel) throws -> Void = { channel in
      events.withLock { $0.append("bind") }
      channel.setIncomingHandler { message in
        events.withLock { $0.append("message") }
        message.reply(message.payload)
      }
    }
    let accepted: @Sendable (XPCChannel) -> Void = { _ in
      events.withLock { $0.append("accepted") }
    }
    let host: XPCServiceHost
    let acceptor: XPCChannelAcceptor
    switch pair.server {
    case .cConnection:
      let delegate = XPCConnectionServiceConfiguration(
        shouldAccept: { connection in
          #expect(connection.pid == getpid())
          events.withLock { $0.append("audit") }
          return true
        }, onPeerAccept: accepted)
      host = XPCServiceHost(delegate, eventLog: log, peerHandler: binding)
      acceptor = try XPCChannelAcceptor(delegate, eventLog: log)
    case .session:
      let delegate = XPCSessionServiceConfiguration(
        shouldAccept: { _ in
          events.withLock { $0.append("audit") }
          return true
        }, onPeerAccept: accepted)
      host = XPCServiceHost(delegate, eventLog: log, peerHandler: binding)
      acceptor = try XPCChannelAcceptor(sessionDelegate: delegate, eventLog: log)
    }
    acceptor.setAcceptHandler { host.bind($0) }
    try acceptor.activate()
    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    defer { client.cancel(); acceptor.cancel(); host.cancel() }
    client.activate()
    _ = try await client.send(XPCDictionary().xpcObject)
    #expect(events.withLock { $0 } == ["audit", "bind", "accepted", "message"])
    #expect(log.events.map(\.kind) == [.shouldAcceptPeer, .didAcceptPeer])
  }

  @Test(arguments: XPCBackendPair.all)
  func BindingFailureIsAServiceRejectionAfterNativeAdmission(pair: XPCBackendPair) async throws {
    struct BindingFailure: Error {}
    let rejected = ErrorBox()
    let nativeRejections = Mutex(0)
    let log = XPCServiceEventLog()
    let didReject: @Sendable (XPCChannel, (any Error)?) -> Void = { _, error in
      rejected.store(error)
    }
    let host: XPCServiceHost
    let acceptor: XPCChannelAcceptor
    let binding: @Sendable (XPCChannel) throws -> Void = { _ in throw BindingFailure() }
    switch pair.server {
    case .cConnection:
      let delegate = XPCConnectionServiceConfiguration(
        onConnectionReject: { _, _ in nativeRejections.withLock { $0 += 1 } },
        onPeerReject: didReject)
      host = XPCServiceHost(delegate, eventLog: log, peerHandler: binding)
      acceptor = try XPCChannelAcceptor(delegate)
    case .session:
      let delegate = XPCSessionServiceConfiguration(
        onSessionReject: { _, _ in nativeRejections.withLock { $0 += 1 } },
        onPeerReject: didReject)
      host = XPCServiceHost(delegate, eventLog: log, peerHandler: binding)
      acceptor = try XPCChannelAcceptor(sessionDelegate: delegate)
    }
    acceptor.setAcceptHandler { host.bind($0) }
    try acceptor.activate()
    let client = try pair.client.channel(dialing: acceptor.wireEndpoint)
    defer { client.cancel(); acceptor.cancel(); host.cancel() }
    client.activate()
    client.sendAndForget(XPCDictionary().xpcObject)
    #expect(rejected.wait(2) is BindingFailure)
    #expect(nativeRejections.withLock { $0 } == 0)
    #expect(log.events.map(\.kind) == [.didRejectPeer])
  }

  @Test(arguments: XPCChannelTransport.allCases, [false, true])
  func SessionNativeRejectionNeverCreatesAnAcceptedChannel(
    clientTransport: XPCChannelTransport, throwsError: Bool
  ) async throws {

    let rejections = ErrorBox()
    let log = XPCServiceEventLog()
    let nativeRejected = FlagBox()
    let accepted = Mutex(0)
    struct Rejected: Error {}
    let delegate = XPCSessionServiceConfiguration(
      shouldAccept: { _ in
        if throwsError { throw Rejected() }
        return false
      },
      onSessionReject: { _, error in
        rejections.store(error)
        nativeRejected.fire()
      },
      onPeerAccept: { _ in accepted.withLock { $0 += 1 } })
    let host = XPCServiceHost(delegate)
    let acceptor = try XPCChannelAcceptor(sessionDelegate: delegate, eventLog: log)
    acceptor.setAcceptHandler { host.bind($0) }
    try acceptor.activate()
    let client = try clientTransport.channel(dialing: acceptor.wireEndpoint)
    client.activate()
    client.sendAndForget(XPCDictionary().xpcObject)
    #expect(nativeRejected.wait(2))
    #expect(log.events.map(\.kind) == [.shouldAcceptPeer, .didRejectSessionRequest])
    let error = rejections.wait(2)
    if throwsError { #expect(error is Rejected) } else { #expect(error == nil) }
    #expect(accepted.withLock { $0 } == 0)
    client.cancel()
    acceptor.cancel()
  }
}
