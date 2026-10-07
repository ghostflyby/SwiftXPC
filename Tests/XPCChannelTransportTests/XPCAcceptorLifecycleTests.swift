// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Synchronization
import Testing
@testable import SwiftXPC

struct XPCAcceptorLifecycleTests {
  @Test func OverlappingActivationDoesNotReportUnfinishedSuccess() throws {
    struct ActivationFailure: Error {}
    let listener = XPCListener(options: [.inactive]) { $0.reject(reason: "test") }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let attempts = Mutex(0)
    let acceptor = XPCChannelAcceptor(testingListener: listener) {
      let attempt = attempts.withLock {
        $0 += 1; return $0
      }
      if attempt == 1 {
        entered.signal()
        #expect(release.wait(timeout: .now() + 5) == .success)
        throw ActivationFailure()
      }
      try listener.activate()
    }
    defer { release.signal(); acceptor.cancel() }
    DispatchQueue.global().async {
      #expect(throws: ActivationFailure.self) { try acceptor.activate() }
      finished.signal()
    }
    #expect(entered.wait(timeout: .now() + 5) == .success)
    #expect(throws: XPCChannelAcceptor.ActivationError.inProgress) { try acceptor.activate() }
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    try acceptor.activate()  // Retry after the owner reported failure.
    try acceptor.activate()  // Completed activation is idempotent.
    #expect(attempts.withLock { $0 } == 2)
  }

  private final class WeakAcceptor: @unchecked Sendable {
    weak var value: XPCChannelAcceptor?
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func CancellationDuringAuditPreventsDelivery(transport: XPCChannelTransport) throws {
    let box = WeakAcceptor()
    let rejected = DispatchSemaphore(value: 0)
    let deliveries = Mutex(0)
    let log = XPCServiceEventLog()
    let handler: @Sendable (XPCChannel) -> Void = { peer in
      deliveries.withLock { $0 += 1 }
      peer.cancel()
    }
    let acceptor: XPCChannelAcceptor
    switch transport {
    case .cConnection:
      acceptor = try XPCChannelAcceptor(
        XPCConnectionServiceConfiguration(
          shouldAccept: { _ in
            box.value?.cancel(); return true
          },
          onConnectionReject: { _, error in
            #expect(error == nil); rejected.signal()
          }),
        eventLog: log, handler: handler)
    case .session:
      acceptor = try XPCChannelAcceptor(
        sessionDelegate: XPCSessionServiceConfiguration(
          shouldAccept: { _ in
            box.value?.cancel(); return true
          },
          onSessionReject: { _, error in
            #expect(error == nil); rejected.signal()
          }),
        eventLog: log, handler: handler)
    }
    box.value = acceptor
    try acceptor.activate()
    let client = try transport.channel(dialing: acceptor.wireEndpoint)
    defer { client.cancel(); acceptor.cancel() }
    client.activate()
    client.sendAndForget(XPCDictionary().xpcObject)
    #expect(rejected.wait(timeout: .now() + 5) == .success)
    #expect(deliveries.withLock { $0 } == 0)
    #expect(
      log.events.map(\.kind) == [
        .shouldAcceptPeer,
        transport == .cConnection ? .didRejectConnection : .didRejectSessionRequest,
      ])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ShutdownHostRejectsLateBindingWithNilError(transport: XPCChannelTransport) async throws {
    let rejected = DispatchSemaphore(value: 0)
    let bindings = Mutex(0)
    let log = XPCServiceEventLog()
    let host = XPCServiceHost(
      XPCConnectionServiceConfiguration(onPeerReject: { _, error in
        #expect(error == nil)
        rejected.signal()
      }), eventLog: log, peerHandler: { _ in bindings.withLock { $0 += 1 } })
    // Keep the raw listener running: this exercises host.bind after shutdown.
    let acceptor = try transport.acceptor(handler: { host.bind($0) })
    try acceptor.activate()
    host.requestShutdown()
    let client = try transport.channel(dialing: acceptor.wireEndpoint)
    defer { client.cancel(); acceptor.cancel(); host.cancel() }
    client.activate()
    let error = await #expect(throws: XPCChannelError.self) {
      _ = try await client.send(XPCDictionary().xpcObject)
    }
    #expect(error == (transport == .cConnection ? .interrupted : .invalid))
    let didReject = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: rejected.wait(timeout: .now() + 5) == .success)
      }
    }
    #expect(didReject)
    #expect(bindings.withLock { $0 } == 0)
    #expect(log.events.map(\.kind) == [.serviceWillShutdown, .didRejectPeer])
  }
}
