// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Synchronization
import SwiftXPC
import Testing

/// Transport tests for the session backend: round trip through the reply
/// sink, fire-and-forget, server pushes, cancellation chains, wire endpoint
/// typing, and mixed-backend interop (C client dialing a session acceptor).
@Suite struct XPCSessionTransportTests {

  private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: XPCIncomingMessage?

    func store(_ message: XPCIncomingMessage) {
      lock.lock()
      value = message
      lock.unlock()
      semaphore.signal()
    }

    func wait(_ timeout: TimeInterval) -> XPCIncomingMessage? {
      guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  @Test func RoundTripThroughDeferredReplySink() async throws {
    let acceptor = try XPCListenerAcceptor()
    let incoming = MessageBox()
    // The delivered channel owns its session: retain it for as long as the
    // connection should live, exactly like a real consumer does.
    let retained = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      retained.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        incoming.store(message)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
          var response = XPCDictionary()
          response["answered"] = true
          message.reply(response.xpcObject)
        }
      }
      channel.activate()
    }
    acceptor.activate()

    let client = XPCSessionChannel(dialing: acceptor.listenerEndpoint)
    client.setIncomingHandler { _ in }
    client.activate()
    var request = XPCDictionary()
    request["ask"] = "roundtrip"
    let reply = try await client.send(request.xpcObject, replyQueue: nil)
    let decoded = XPCDictionary(reply)
    #expect(decoded["answered"] == true)
  }

  @Test func SendAndForgetAndServerPush() async throws {
    let acceptor = try XPCListenerAcceptor()
    let serverIncoming = MessageBox()
    let pushed = MessageBox()
    let acceptChannelBox = Mutex<(any XPCMessageChannel)?>(nil)
    acceptor.setAcceptHandler { channel in
      acceptChannelBox.withLock { $0 = channel }
      channel.setIncomingHandler { message in
        serverIncoming.store(message)
        guard let serverChannel = acceptChannelBox.withLock({ $0 }),
          let sessionChannel = serverChannel as? XPCSessionChannel
        else { return }
        var push = XPCDictionary()
        push["pushed"] = true
        sessionChannel.sendAndForget(push.xpcObject)
      }
      channel.activate()
    }
    acceptor.activate()

    let client = XPCSessionChannel(dialing: acceptor.listenerEndpoint)
    client.setIncomingHandler { message in
      pushed.store(message)
    }
    client.activate()
    var request = XPCDictionary()
    request["forget"] = true
    client.sendAndForget(request.xpcObject)

    let received = serverIncoming.wait(5)
    #expect(received != nil)
    let decoded = received.map { XPCDictionary($0.payload) }
    #expect(decoded?["forget"] == true)

    let pushedMessage = pushed.wait(5)
    let pushedDecoded = pushedMessage.map { XPCDictionary($0.payload) }
    #expect(pushedDecoded?["pushed"] == true)
  }

  @Test func CancelFiresTerminalChain() throws {
    let acceptor = try XPCListenerAcceptor()
    let invalidated = DispatchSemaphore(value: 0)
    acceptor.setAcceptHandler { channel in
      channel.activate()
    }
    acceptor.activate()

    let client = XPCSessionChannel(dialing: acceptor.listenerEndpoint)
    client.setIncomingHandler { _ in }
    client.activate()
    // Manual cancel is terminal: route to the invalidation chain.
    client.addInvalidationHandler { invalidated.signal() }
    client.addInterruptionHandler {
      Issue.record("interruption chain must not fire on cancel")
    }

    var ping = XPCDictionary()
    ping["wake"] = true
    client.sendAndForget(ping.xpcObject)
    Thread.sleep(forTimeInterval: 0.05)
    client.cancel()

    #expect(invalidated.wait(timeout: DispatchTime.now() + 5) == .success)
  }

  @Test func WireEndpointIsEndpointObject() async throws {
    let acceptor = try XPCListenerAcceptor()
    #expect(xpc_get_type(acceptor.wireEndpoint) == XPC_TYPE_ENDPOINT)
  }

  @Test func MixedBackendCClientDialsSessionAcceptor() async throws {
    let acceptor = try XPCListenerAcceptor()
    let serverIncoming = MessageBox()
    acceptor.setAcceptHandler { channel in
      channel.setIncomingHandler { message in
        serverIncoming.store(message)
      }
      channel.activate()
    }
    acceptor.activate()

    // C-backend client dialing the session acceptor's wire endpoint.
    let cClient = try XPCConnection.unmarshal(from: acceptor.wireEndpoint)
    cClient.setIncomingHandler { _ in }
    cClient.activate()
    var request = XPCDictionary()
    request["fromC"] = true
    cClient.sendAndForget(message: request)

    let received = serverIncoming.wait(5)
    #expect(received != nil)
    let decoded = received.map { XPCDictionary($0.payload) }
    #expect(decoded?["fromC"] == true)
    cClient.cancel()
  }
}
