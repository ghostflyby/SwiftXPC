// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization

/// How often and with which backoff a flaky transport operation is retried.
/// Only infrastructure failures (`XPCChannelError`) are retried; errors
/// thrown by the operation itself propagate immediately.
public struct XPCRetryPolicy: Sendable {
  /// Total number of attempts, including the first one. Must be >= 1.
  public let maxAttempts: Int
  /// Wait before the first retry.
  public let initialBackoff: Duration
  /// Growth factor applied to the wait after each failed attempt.
  public let multiplier: Double
  /// Upper bound for any single wait.
  public let maxBackoff: Duration

  /// A single attempt, never retried.
  public static let once = XPCRetryPolicy(
    maxAttempts: 1, initialBackoff: .zero, multiplier: 1, maxBackoff: .zero)

  /// Tolerates a service restart: retries for up to ~11.3s of cumulative wait.
  public static let resilient = XPCRetryPolicy(
    maxAttempts: 8, initialBackoff: .milliseconds(100), multiplier: 2, maxBackoff: .seconds(5))

  public init(
    maxAttempts: Int,
    initialBackoff: Duration,
    multiplier: Double,
    maxBackoff: Duration
  ) {
    precondition(maxAttempts >= 1, "maxAttempts must be >= 1")
    self.maxAttempts = maxAttempts
    self.initialBackoff = initialBackoff
    self.multiplier = multiplier
    self.maxBackoff = maxBackoff
  }

  fileprivate func delaySeconds(beforeAttempt attempt: Int) -> Double {
    func seconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
    guard attempt >= 2 else { return 0 }
    let scaled = seconds(initialBackoff) * pow(multiplier, Double(attempt - 2))
    return min(scaled, seconds(maxBackoff))
  }
}

/// Lifecycle events of a root connection.
public enum XPCRootConnectionEvent: Sendable {
  /// The connection to the service is established.
  case connected
  /// The underlying connection was invalidated or interrupted (service
  /// exited, crashed, or was cancelled). May be delivered multiple times for
  /// repeated service deaths. Named-service connections re-establish
  /// transparently on the next call, but child actor proxies obtained before
  /// this event are permanently stale and must be re-acquired through `root`.
  case disconnected
}

/// A resilient handle to a service's root actor.
///
/// Unlike child actor references, the root proxy rides a *named* mach service
/// connection: when the service process dies, launchd relaunches it and the
/// same proxy transparently works again on its next call. This handle adds
/// lifecycle events and a retry policy for infrastructure failures. Callers
/// observe `events` to rebuild dependent child-actor state after
/// `.disconnected`.
public final class XPCRootConnection<Root: XPCRootActor>: Sendable {
  /// The permanent root proxy. Never needs replacement: after a service
  /// restart the next call on it succeeds against the relaunched instance.
  public let root: Root
  public let connection: any XPCMessageChannel
  public let events: AsyncStream<XPCRootConnectionEvent>

  /// Retained so the owned connection outlives proxies created from it.
  private let system: XPCDistributedActorSystem

  private struct State {
    var continuation: AsyncStream<XPCRootConnectionEvent>.Continuation?
    var closed = false
  }
  private let state = Mutex(State())

  private init(
    root: Root, connection: any XPCMessageChannel, system: XPCDistributedActorSystem
  ) {
    self.root = root
    self.connection = connection
    self.system = system
    var continuation: AsyncStream<XPCRootConnectionEvent>.Continuation!
    self.events = AsyncStream { continuation = $0 }
    state.withLock { $0.continuation = continuation }
    emit(.connected)
    // Peer death arrives as INVALID on hard crashes and INTERRUPTED when the
    // service cancels the peer gracefully; both mean "channel is down". The
    // invalidation handler additionally fires immediately if the channel
    // was already invalidated before this install (connect resolved the root
    // on an activated channel), so `.disconnected` is never missed.
    connection.addInvalidationHandler { [weak self] in
      self?.emit(.disconnected)
    }
    connection.addInterruptionHandler { [weak self] in
      self?.emit(.disconnected)
    }
  }

  /// Connects to a launchd-managed XPC service by mach service name and
  /// resolves its root actor. This is the reconnection-capable path on the C
  /// backend: after a service restart, calls on `root` transparently succeed
  /// again (the session backend does not re-dial — a dropped session channel
  /// is terminal).
  ///
  /// - Parameters:
  ///   - serviceName: the launchd mach service name of the service.
  ///   - transport: the backend to dial with; defaults to the process
  ///     default.
  ///   - peerCodeSigningRequirement: kernel-enforced requirement the service
  ///     must satisfy, installed on the channel before activation. A
  ///     service failing it is dropped by XPC; a requirement that cannot be
  ///     installed (including the session backend's fail-closed `ENOTSUP`)
  ///     makes `connect` throw.
  public static func connect(
    toService serviceName: String,
    transport: XPCChannelTransport = XPCChannelTransport.processDefault,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try connect(
      using: transport.channel(machService: serviceName),
      peerCodeSigningRequirement: peerCodeSigningRequirement)
  }

  /// Connects through an existing channel. Note: only C-backend connections
  /// to a *named* mach service survive a full service restart. An
  /// endpoint-based channel re-dials across a dropped peer while the remote
  /// listener lives (C backend), but dies permanently once the listener
  /// itself goes away (anonymous endpoints are not re-established by
  /// launchd).
  ///
  /// `peerCodeSigningRequirement` authenticates the service and must be
  /// installed on a *not-yet-activated* channel. On an already-activated
  /// channel the install reports success but the channel then fails to
  /// establish (hangs or interrupts) — pass a fresh channel.
  public static func connect(
    using connection: any XPCMessageChannel,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try connection.applyPeerCodeSigningRequirement(peerCodeSigningRequirement)
    let system = XPCDistributedActorSystem(connection: connection, ownsConnection: true)
    connection.activate()
    let root = try Root.resolve(id: .root, using: system)
    return self.init(root: root, connection: connection, system: system)
  }

  /// Runs `operation` against the root actor, retrying only when the
  /// infrastructure fails (`XPCChannelError.invalid`/`.interrupted`), which
  /// covers a service restart in progress. Business errors propagate at once.
  public func retrying<T>(
    _ policy: XPCRetryPolicy = .resilient,
    _ operation: @Sendable (Root) async throws -> T
  ) async throws -> T {
    var attempt = 0
    while true {
      attempt += 1
      do {
        return try await operation(root)
      } catch let error as XPCChannelError {
        // Authentication failure is terminal, never a restart in progress.
        if case .peerCodeSigningRequirement = error { throw error }
        if attempt >= policy.maxAttempts { throw error }
      }
      let delay = policy.delaySeconds(beforeAttempt: attempt + 1)
      if delay > 0 {
        try await Task.sleep(for: .seconds(delay))
      }
    }
  }

  /// Cancels the connection and finishes the event stream.
  public func close() {
    let continuation = state.withLock { state in
      state.closed = true
      return state.continuation
    }
    continuation?.finish()
    connection.cancel()
  }

  private func emit(_ event: XPCRootConnectionEvent) {
    let continuation = state.withLock {
      state -> AsyncStream<XPCRootConnectionEvent>.Continuation? in
      if state.closed { return nil }
      return state.continuation
    }
    continuation?.yield(event)
  }
}
