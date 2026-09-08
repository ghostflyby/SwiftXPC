// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Darwin
@testable import SwiftXPC
import Synchronization
import Testing
import XPC

@available(macOS 15.0, *)
private final class EventLog: @unchecked Sendable {
  private let items = Mutex<[String]>([])

  func record(_ name: String) {
    items.withLock { $0.append(name) }
  }

  var values: [String] {
    items.withLock { $0 }
  }
}

@available(macOS 15.0, *)
private func assertRouting(
  _ object: XPCObject,
  configured: @Sendable (_ConnectionHandlerState, EventLog) -> Void = { _, _ in },
  expected: [String],
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let state = _ConnectionHandlerState()
  let log = EventLog()
  state.genericHandler = { _ in log.record("generic") }
  state.invalidationHandler = { log.record("invalid") }
  state.interruptionHandler = { log.record("interrupted") }
  configured(state, log)
  routeConnectionEvent(state, object)
  #expect(log.values == expected, sourceLocation: sourceLocation)
}

@Test func RoutingSendsInvalidToInvalidationHandler() async throws {
  guard #available(macOS 15.0, *) else { return }
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_CONNECTION_INVALID),
    expected: ["invalid"])
}

@Test func RoutingSendsInterruptedToInterruptionHandler() async throws {
  guard #available(macOS 15.0, *) else { return }
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_CONNECTION_INTERRUPTED),
    expected: ["interrupted"])
}

@Test func RoutingSendsTerminationImminentToDedicatedHandler() async throws {
  guard #available(macOS 15.0, *) else { return }
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_TERMINATION_IMMINENT),
    configured: { state, log in
      state.terminationImminentHandler = { log.record("termination") }
    },
    expected: ["termination"])
}

@Test func RoutingFallsBackToGenericWithoutTerminationHandler() async throws {
  guard #available(macOS 15.0, *) else { return }
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_TERMINATION_IMMINENT),
    expected: ["generic"])
}

@Test func RoutingSendsPeerCodeSigningErrorToDedicatedHandler() async throws {
  guard #available(macOS 15.0, *) else { return }
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT),
    configured: { state, log in
      state.peerCodeSigningErrorHandler = { log.record("peer-error") }
    },
    expected: ["peer-error"])
}

@Test func RoutingFallsBackToGenericWithoutPeerCodeSigningHandler() async throws {
  guard #available(macOS 15.0, *) else { return }
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT),
    expected: ["generic"])
}

@Test func RoutingSendsPlainMessagesToGenericHandler() async throws {
  guard #available(macOS 15.0, *) else { return }
  assertRouting(
    try "message".marshal(),
    expected: ["generic"])
}

@Test func ConnectionExposesPeerPidAndDebugDescription() async throws {
  guard #available(macOS 15.0, *) else { return }
  let listener = XPCConnection(name: nil)
  let accepted = Mutex<XPCConnection?>(nil)
  listener.setEventHandler { object in
    guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
    accepted.withLock { $0 = XPCConnection(xpc_object: object.xpc_object) }
  }
  listener.activate()

  let client = try XPCConnection.unmarshal(from: listener.marshal())
  client.setEventHandler { _ in }
  client.activate()
  client.sendAndForget(message: XPCDictionary())

  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline, accepted.withLock({ $0 }) == nil {
    try await Task.sleep(for: .milliseconds(10))
  }
  let peer = try #require(accepted.withLock { $0 })
  #expect(peer.pid == getpid())
  #expect(!client.debugDescription.isEmpty)
  let payload = try "payload".marshal()
  #expect(!payload.debugDescription.isEmpty)

  // A never-activated connection traps on release; retire the accepted peer
  // through the safe activate-then-cancel sequence.
  peer.setEventHandler { _ in }
  peer.activate()
  peer.cancel()
  client.cancel()
  listener.cancel()
}
