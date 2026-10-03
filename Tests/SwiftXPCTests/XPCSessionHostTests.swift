// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Synchronization
import DistributedXPC
import SwiftXPC
import Testing

/// Integration tests for the unified `XPCServiceHost` over the session
/// backend: acceptance, an echo service over an accepted channel, and the
/// cooperative shutdown pipeline — the same host semantics the C backend
/// exercises in `XPCServiceDelegateTests`.
@Suite struct XPCSessionHostTests {

  private final class ShutdownBox: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private let semaphore = DispatchSemaphore(value: 0)

    func fire() {
      lock.lock()
      let first = !called
      called = true
      lock.unlock()
      if first { semaphore.signal() }
    }

    func wait(_ timeout: TimeInterval) -> Bool {
      semaphore.wait(timeout: .now() + timeout) == .success
    }
  }

  private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (XPCChannel)?
    let stored = DispatchSemaphore(value: 0)

    func store(_ channel: XPCChannel) {
      lock.lock()
      value = channel
      lock.unlock()
      stored.signal()
    }

    func wait(_ timeout: TimeInterval) -> (XPCChannel)? {
      guard stored.wait(timeout: .now() + timeout) == .success else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  @Test func UnifiedHostAcceptsEchoesAndShutsDownCooperativelyOverSession() async throws {
    let shutdown = ShutdownBox()
    let accepted = ChannelBox()

    let host = XPCServiceHost(
      XPCSessionServiceConfiguration(),
      peerHandler: { channel in
        // An echo "service": the peer handler installs the incoming routing.
        channel.setIncomingHandler { message in
          // The lazy-dial wake message is fire-and-forget: never reply to it.
          if XPCDictionary(message.payload)["wake"] != nil { return }
          var response = XPCDictionary()
          response["echo"] = XPCDictionary(message.payload)["ping", as: xpc_object_t.self]
          message.reply(response.xpcObject)
        }
      }, onShutdown: { shutdown.fire() })

    let acceptor = try XPCChannelTransport.session.acceptor()
    acceptor.setAcceptHandler { channel in
      accepted.store(channel)
      host.bind(channel)
    }
    try acceptor.activate()

    let client = try XPCChannelTransport.session.channel(dialing: acceptor.wireEndpoint)
    client.setIncomingHandler { _ in }
    client.activate()
    // A session dials lazily: the first send establishes the connection.
    var wake = XPCDictionary()
    wake["wake"] = true
    client.sendAndForget(wake.xpcObject)

    // Wait for the host to accept the server-side channel. Messages that
    // raced the host's incoming-handler install are buffered by the channel
    // and flushed once it runs, so the ordering is safe either way.
    guard let serverChannel = accepted.wait(5) else {
      Issue.record("host never accepted the channel")
      return
    }

    var ping = XPCDictionary()
    ping["ping"] = "hello"
    let reply = try await client.send(ping.xpcObject)
    #expect(XPCDictionary(reply)["echo"] == "hello")

    // Cooperative shutdown: cancels accepted channels and fires completion.
    host.requestShutdown()
    #expect(shutdown.wait(5))
    #expect(serverChannel != nil)
  }
}
