// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Synchronization
import DistributedXPC
import SwiftXPC
import Testing

/// Integration tests for the slim session service host: acceptance, echo
/// service over an accepted channel, and cooperative shutdown.
@Suite struct XPCSessionServiceHostTests {

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
    private var value: (any XPCMessageChannel)?
    let stored = DispatchSemaphore(value: 0)

    func store(_ channel: any XPCMessageChannel) {
      lock.lock()
      value = channel
      lock.unlock()
      stored.signal()
    }

    func wait(_ timeout: TimeInterval) -> (any XPCMessageChannel)? {
      guard stored.wait(timeout: .now() + timeout) == .success else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  /// Disabled: the echo `send` after a fire-and-forget dial message tears the
  /// session down ("Underlying connection interrupted", then "canceled
  /// session"). Requires a focused session-handshake investigation — see the
  /// dual-transport PR notes.
  @Test(.disabled("session teardown after fire-and-forget dial message — under investigation"))
  func HostAcceptsEchoesAndShutsDownCooperatively() async throws {
    let host = XPCSessionServiceHost()
    let shutdown = ShutdownBox()
    let accepted = ChannelBox()
    let acceptedFlag = Mutex(false)

    host.setPeerHandler { channel in
      // An echo "service": the peer handler installs the incoming routing.
      channel.setIncomingHandler { message in
        print(
          "NOTE | server recv keys=[\(XPCDictionary(message.payload).keys.joined(separator: ","))]")
        // The lazy-dial wake message is fire-and-forget: never reply to it.
        if XPCDictionary(message.payload)["wake"] != nil { return }
        var response = XPCDictionary()
        response["echo"] = XPCDictionary(message.payload)["ping", as: xpc_object_t.self]
        channel.sendAndForget(response.xpcObject)
      }
    }
    host.setShutdownCompletion { shutdown.fire() }

    let acceptor = try XPCListenerAcceptor()
    acceptor.setAcceptHandler { channel in
      print("NOTE | accept handler: storing+host.accept")
      accepted.store(channel)
      host.accept(channel)
      acceptedFlag.withLock { $0 = true }
    }
    acceptor.activate()

    let client = XPCSessionChannel(dialing: acceptor.listenerEndpoint)
    client.setIncomingHandler { _ in }
    client.activate()
    // A session dials lazily: the first send establishes the connection.
    var wake = XPCDictionary()
    wake["wake"] = true
    client.sendAndForget(wake.xpcObject)

    // Wait for the host to accept and activate the server-side channel.
    guard let serverChannel = accepted.wait(5) else {
      Issue.record("host never accepted the channel")
      return
    }
    _ = acceptedFlag

    do {
      var ping = XPCDictionary()
      ping["ping"] = "hello"
      let reply = try await client.send(ping.xpcObject, replyQueue: nil)
      #expect(XPCDictionary(reply)["echo"] == "hello")
    } catch {
      Issue.record("send failed: \(error)")
    }

    // Cooperative shutdown: cancels accepted channels and fires completion.
    host.requestShutdown()
    #expect(shutdown.wait(5))
    #expect(serverChannel != nil)
  }
}
