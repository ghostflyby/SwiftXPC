// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

/// One recorded delegate-hook invocation, for test assertions.
///
/// Events are appended in invocation order. Peer identity is not tracked —
/// distinguish peers by order and counts.
@available(macOS 15, *)
public struct XPCServiceEvent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// The audit window was entered for an incoming peer.
    case shouldAcceptPeer
    /// A peer was accepted (bound to the service, before activation).
    case didAcceptPeer
    /// An accepted peer disconnected.
    case peerDidEnd
    /// A peer was rejected before ever being accepted.
    case didRejectPeer
    /// The cooperative shutdown pipeline ran its delegate hook.
    case serviceWillShutdown
  }

  public let kind: Kind
  /// The rejection/failure description the host reported, when any.
  public let errorDescription: String?

  init(kind: Kind, errorDescription: String?) {
    self.kind = kind
    self.errorDescription = errorDescription
  }
}

/// An append-only recorder for `XPCServiceEvent`s with deterministic async
/// waiting. Pass one to a host (or `xpcTest(_:_:eventLog:watchdog:)`) to
/// assert the delegate-hook sequence:
///
///     let log = XPCServiceEventLog()
///     let service = try xpcTest(ServiceRoot.self, XPCServiceConfiguration(), eventLog: log)
///     _ = try await service.client.root.ping()
///     service.host.requestShutdown()
///     #expect(await log.expectEvent(.serviceWillShutdown) != nil)
///     #expect(log.events.map(\.kind) == [
///       .shouldAcceptPeer, .didAcceptPeer, .serviceWillShutdown])
///
/// `expectEvent(_:timeout:)` never polls: it returns immediately when the
/// event is already recorded, otherwise it suspends and is resumed by the
/// recording itself — a missed edge-triggered event is impossible.
@available(macOS 15, *)
public final class XPCServiceEventLog: @unchecked Sendable {
  private struct Waiter {
    let id = UUID()
    let kind: XPCServiceEvent.Kind
    let atLeast: Int
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let lock = NSLock()
  private var recordedEvents: [XPCServiceEvent] = []
  private var waiters: [Waiter] = []

  public init() {}

  /// Snapshot of the recorded events, in invocation order.
  public var events: [XPCServiceEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }

  /// Appends one event. Intentionally public: a service can append custom
  /// marker events between hook invocations, and tests can assert on the
  /// combined timeline. Appending resumes any waiter for this kind.
  public func append(
    _ kind: XPCServiceEvent.Kind,
    error: (any Error)? = nil
  ) {
    let event = XPCServiceEvent(
      kind: kind,
      errorDescription: error.map(String.init(describing:)))
    lock.lock()
    recordedEvents.append(event)
    var released: [CheckedContinuation<Bool, Never>] = []
    while let index = waiters.firstIndex(where: {
      $0.kind == event.kind
        && recordedEvents.filter { $0.kind == event.kind }.count >= $0.atLeast
    }) {
      released.append(waiters.remove(at: index).continuation)
    }
    lock.unlock()
    released.forEach { $0.resume(returning: true) }
  }

  /// Deterministically waits until an event of `kind` has been recorded and
  /// returns it. Returns immediately when one is already in the log;
  /// otherwise suspends until the append that records it. Returns `nil`
  /// when `timeout` elapses first. Never polls — use `expectCount` for
  /// occurrences beyond the first.
  public func expectEvent(
    _ kind: XPCServiceEvent.Kind,
    timeout: Duration? = nil
  ) async -> XPCServiceEvent? {
    guard await expectCount(kind, atLeast: 1, timeout: timeout) else { return nil }
    return recorded(kind)
  }

  /// Deterministically waits until `count` events of `kind` have been
  /// recorded. Returns immediately when already satisfied; otherwise
  /// suspends until the append that reaches the threshold. Returns `false`
  /// when `timeout` elapses first. Never polls.
  public func expectCount(
    _ kind: XPCServiceEvent.Kind,
    atLeast count: Int,
    timeout: Duration? = nil
  ) async -> Bool {
    if satisfied(kind, atLeast: count) { return true }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      insertWaiter(kind: kind, atLeast: count, continuation: cont, timeout: timeout)
    }
  }

  private func recorded(_ kind: XPCServiceEvent.Kind) -> XPCServiceEvent? {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents.first(where: { $0.kind == kind })
  }

  private func satisfied(_ kind: XPCServiceEvent.Kind, atLeast count: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents.filter { $0.kind == kind }.count >= count
  }

  private func insertWaiter(
    kind: XPCServiceEvent.Kind,
    atLeast count: Int,
    continuation: CheckedContinuation<Bool, Never>,
    timeout: Duration?
  ) {
    lock.lock()
    defer { lock.unlock() }
    if recordedEvents.filter({ $0.kind == kind }).count >= count {
      continuation.resume(returning: true)
      return
    }
    let waiter = Waiter(kind: kind, atLeast: count, continuation: continuation)
    waiters.append(waiter)

    if let timeout {
      let registry = self
      let deadline =
        DispatchTime.now()
        + Double(timeout.components.seconds)
        + Double(timeout.components.attoseconds) * 1e-18
      DispatchQueue.global().asyncAfter(deadline: deadline) {
        registry.cancelWaiter(id: waiter.id)
      }
    }
  }

  private func cancelWaiter(id: UUID) {
    lock.lock()
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return
    }
    let waiter = waiters.remove(at: index)
    lock.unlock()
    waiter.continuation.resume(returning: false)
  }
}
