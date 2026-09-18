// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Darwin
@testable import SwiftXPC
import Synchronization
import Testing
import XPC

private final class EventLog: Sendable {
  private let items = Mutex<[String]>([])

  func record(_ name: String) {
    items.withLock { $0.append(name) }
  }

  var values: [String] {
    items.withLock { $0 }
  }
}

private func assertRouting(
  _ object: XPCObject,
  configured: @Sendable (_ConnectionHandlerState, EventLog) -> Void = { _, _ in },
  expected: [String],
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let state = _ConnectionHandlerState()
  let log = EventLog()
  state.setGenericHandler { _ in log.record("generic") }
  state.chain(\.invalidation, { log.record("invalid") })
  state.chain(\.interruption, { log.record("interrupted") })
  configured(state, log)
  state.route(object)
  #expect(log.values == expected, sourceLocation: sourceLocation)
}

@Test func RoutingSendsInvalidToInvalidationHandler() async throws {
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_CONNECTION_INVALID),
    expected: ["invalid"])
}

@Test func RoutingSendsInterruptedToInterruptionHandler() async throws {
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_CONNECTION_INTERRUPTED),
    expected: ["interrupted"])
}

@Test func RoutingSendsTerminationImminentToDedicatedHandler() async throws {
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_TERMINATION_IMMINENT),
    configured: { state, log in
      state.chain(\.terminationImminent, { log.record("termination") })
    },
    expected: ["termination"])
}

@Test func RoutingFallsBackToGenericWithoutTerminationHandler() async throws {
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_TERMINATION_IMMINENT),
    expected: ["generic"])
}

@Test func RoutingSendsPeerCodeSigningErrorToDedicatedHandler() async throws {
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT),
    configured: { state, log in
      state.chain(\.peerCodeSigningError, { log.record("peer-error") })
    },
    expected: ["peer-error"])
}

@Test func RoutingFallsBackToGenericWithoutPeerCodeSigningHandler() async throws {
  assertRouting(
    XPCObject(xpc_object: XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT),
    expected: ["generic"])
}

@Test func RoutingSendsPlainMessagesToGenericHandler() async throws {
  assertRouting(
    try "message".marshal(),
    expected: ["generic"])
}

@Test func InvalidationHandlerAddedAfterDeliveryRunsImmediately() {
  // Invalidation is terminal and delivered once; a handler installed after
  // delivery must still observe it (XPCRootConnection installs its handlers
  // on an already-activated channel). `chainInvalidation` reports the
  // already-delivered case so the caller invokes the handler itself.
  let state = _ConnectionHandlerState()
  state.route(XPCObject(xpc_object: XPC_ERROR_CONNECTION_INVALID))

  #expect(state.chainInvalidation {} == true)
}

@Test func WaitForDisconnectionResumesOnInterruption() async throws {
  // A graceful peer cancel surfaces as INTERRUPTED, not INVALID; the wait
  // must resume on either signal or callers hang forever.
  let state = _ConnectionHandlerState()
  let waiter = Task {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      state.waitForDisconnection(continuation: cont)
    }
  }
  try await Task.sleep(for: .milliseconds(50))
  state.route(XPCObject(xpc_object: XPC_ERROR_CONNECTION_INTERRUPTED))

  let resumed = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await waiter.value
      return true
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(5))
      return false
    }
    let first = await group.next()!
    group.cancelAll()
    return first
  }
  #expect(resumed)
}

@Test func WaitForDisconnectionResumesOnInvalidation() async throws {
  let state = _ConnectionHandlerState()
  let waiter = Task {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      state.waitForDisconnection(continuation: cont)
    }
  }
  try await Task.sleep(for: .milliseconds(50))
  state.route(XPCObject(xpc_object: XPC_ERROR_CONNECTION_INVALID))

  let resumed = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await waiter.value
      return true
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(5))
      return false
    }
    let first = await group.next()!
    group.cancelAll()
    return first
  }
  #expect(resumed)
}

@Test func WaitForDisconnectionResumesImmediatelyAfterDelivery() async throws {
  let state = _ConnectionHandlerState()
  state.route(XPCObject(xpc_object: XPC_ERROR_CONNECTION_INTERRUPTED))
  // Already down: the wait must not suspend.
  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    state.waitForDisconnection(continuation: cont)
  }
}

@Test func ConnectionExposesPeerPidAndDebugDescription() async throws {
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
