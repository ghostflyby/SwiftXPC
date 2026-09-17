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

/// An append-only recorder for `XPCServiceEvent`s. Pass one to a host (or
/// `xpcTest(_:_:eventLog:watchdog:)`) to assert the delegate-hook sequence:
///
///     let log = XPCServiceEventLog()
///     let service = try xpcTest(ServiceRoot.self, XPCServiceConfiguration(), eventLog: log)
///     _ = try await service.channel.root.ping()
///     service.host.requestShutdown()
///     #expect(log.events.map(\.kind) == [
///       .shouldAcceptPeer, .didAcceptPeer, .serviceWillShutdown])
///
/// Pairs naturally with Swift Testing's
/// `confirmation(expectedCount:)`: pass `confirmation`-resuming closures as
/// delegate hooks for count assertions, and use the log for order.
@available(macOS 15, *)
public final class XPCServiceEventLog: Sendable {
  private let state = Mutex<[XPCServiceEvent]>([])

  public init() {}

  /// Snapshot of the recorded events, in invocation order.
  public var events: [XPCServiceEvent] {
    state.withLock { $0 }
  }

  /// Appends one event. Intentionally public: a service can append custom
  /// marker events between hook invocations, and tests can assert on the
  /// combined timeline.
  public func append(
    _ kind: XPCServiceEvent.Kind,
    error: (any Error)? = nil
  ) {
    state.withLock {
      $0.append(
        XPCServiceEvent(
          kind: kind,
          errorDescription: error.map(String.init(describing:))))
    }
  }
}
