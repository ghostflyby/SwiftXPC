// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// Owns admitted channels, message routing, and cooperative shutdown.
/// Native connection/session admission belongs to `XPCChannelAcceptor`.
/// Routing and shutdown completion are fixed at construction, so another
/// layer cannot replace an actor service's routing or registry cleanup.
public final class XPCServiceHost: Sendable {
  struct State {
    var channels: [UUID: XPCChannel] = [:]
    var cancelled = false
    var shutdownRequested = false
    var shutdownNotified = false
    var shutdownWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
  }

  private let state = Mutex(State())
  private let delegate: any XPCServiceDelegate
  private let eventLog: XPCServiceEventLog?
  private let peerHandler: @Sendable (XPCChannel) throws -> Void
  private let shutdownCompletion: @Sendable () -> Void
  private let managedBinding: (@Sendable (XPCChannel) -> Void)?
  private let managedShutdown: (@Sendable () -> Void)?
  private let managedCancel: (@Sendable () -> Void)?
  /// The host never exits the process. `onShutdown` runs after the delegate
  /// notification; hosted entry points use it to retire their process.
  public init(
    _ delegate: some XPCServiceDelegate,
    eventLog: XPCServiceEventLog? = nil,
    peerHandler: @escaping @Sendable (XPCChannel) throws -> Void = { _ in },
    onShutdown: @escaping @Sendable () -> Void = {}
  ) {
    self.delegate = delegate
    self.eventLog = eventLog
    self.peerHandler = peerHandler
    self.shutdownCompletion = onShutdown
    managedBinding = nil
    managedShutdown = nil
    managedCancel = nil
  }

  private struct DefaultDelegate: XPCServiceDelegate {}

  // A fixed owner pipeline; no externally replaceable routing or cleanup.
  package init(
    eventLog: XPCServiceEventLog?,
    binding: @escaping @Sendable (XPCChannel) -> Void,
    shutdown: @escaping @Sendable () -> Void,
    cancellation: @escaping @Sendable () -> Void
  ) {
    delegate = DefaultDelegate()
    self.eventLog = eventLog
    peerHandler = { _ in }
    shutdownCompletion = {}
    managedBinding = binding
    managedShutdown = shutdown
    managedCancel = cancellation
  }

  /// Registers an owned peer without opening its message-dispatch gate.
  package func register(_ channel: XPCChannel, onEnd: @escaping @Sendable () -> Void) -> Bool {
    let key = UUID()
    let accepted = state.withLock { state in
      guard !state.cancelled, !state.shutdownRequested else { return false }
      state.channels[key] = channel
      return true
    }
    guard accepted else { return false }
    record(.didAcceptPeer)
    channel.addInvalidationHandler { [weak self] in
      guard let self else { return }
      let removed = self.state.withLock { $0.channels.removeValue(forKey: key) }
      self.record(.peerDidEnd)
      onEnd()
      withExtendedLifetime(removed) {}
    }
    return true
  }

  package func recordBindingFailure(_ error: any Error) {
    record(.didRejectPeer, error: error)
  }

  package func completeShutdown() { notifyShutdown() }

  public convenience init(
    eventLog: XPCServiceEventLog? = nil,
    peerHandler: @escaping @Sendable (XPCChannel) throws -> Void = { _ in },
    onShutdown: @escaping @Sendable () -> Void = {}
  ) {
    self.init(
      DefaultDelegate(), eventLog: eventLog, peerHandler: peerHandler, onShutdown: onShutdown)
  }

  private func record(_ kind: XPCServiceEvent.Kind, error: (any Error)? = nil) {
    eventLog?.append(kind, error: error)
  }

  package var isAccepting: Bool {
    state.withLock { !$0.cancelled && !$0.shutdownRequested }
  }

  deinit { cancel() }

  /// Binds and activates a channel already admitted by its native backend.
  /// Binding failure or a closed host cancels it and calls `didRejectPeer`.
  /// Actor-owned hosts first await their typed owner's preparation hooks;
  /// this call queues that work and returns immediately.
  public func bind(_ channel: XPCChannel) {
    if let managedBinding { return managedBinding(channel) }
    let peer = channel

    func reject(_ error: (any Error)?) {
      channel.setIncomingHandler { _ in }
      channel.cancel()
      record(.didRejectPeer, error: error)
      delegate.didRejectPeer(peer, error: error)
    }

    // Native admission already finished; a closed host must not install routing.
    if state.withLock({ $0.shutdownRequested || $0.cancelled }) {
      return reject(nil)
    }

    do {
      try peerHandler(channel)
    } catch {
      return reject(error)
    }
    let key = UUID()
    let accepted = state.withLock { state -> Bool in
      guard !state.cancelled, !state.shutdownRequested else { return false }
      state.channels[key] = channel
      return true
    }
    guard accepted else { return reject(nil) }
    record(.didAcceptPeer)
    delegate.didAcceptPeer(peer)
    channel.addInvalidationHandler { [weak self, channel] in
      guard let self else { return }
      self.record(.peerDidEnd)
      self.delegate.peerDidEnd(channel)
      let removed = self.state.withLock { $0.channels.removeValue(forKey: key) }
      withExtendedLifetime(removed) {}
    }
    channel.activate()
  }

  /// Immediately tears every accepted peer down and closes the host to new
  /// peers, then runs the cooperative shutdown pipeline:
  /// `serviceWillShutdown()` followed by the shutdown completion (when one
  /// is installed). In-flight invocations are not drained. Idempotent:
  /// later calls return without re-running any of it. An actor-owned host
  /// delegates its asynchronous pipeline to its owner; use `waitForShutdown`
  /// to wait for all typed hooks and registry cleanup.
  public func requestShutdown() {
    let first = state.withLock { state -> Bool in
      if state.shutdownRequested || state.cancelled { return false }
      state.shutdownRequested = true
      return true
    }
    guard first else { return }
    if let managedShutdown { return managedShutdown() }
    cancel()
    record(.serviceWillShutdown)
    delegate.serviceWillShutdown()
    shutdownCompletion()
    notifyShutdown()
  }

  /// Deterministically waits until a cooperative shutdown has run its
  /// pipeline and returns `true`. Returns immediately when the host already
  /// shut down; returns `false` when `timeout` elapses first or when the
  /// host was cancelled before a shutdown request. A later explicit request
  /// is a no-op after terminal cancellation. A waiter arriving while the pipeline is mid-flight
  /// — after cancellation, before the hook and completion have finished —
  /// resolves with `true` once the pipeline completes. Never polls.
  public func waitForShutdown(timeout: Duration? = nil) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      insertShutdownWaiter(id: UUID(), continuation: cont, timeout: timeout)
    }
  }

  private func insertShutdownWaiter(
    id: UUID,
    continuation: CheckedContinuation<Bool, Never>,
    timeout: Duration?
  ) {
    let immediateResult = state.withLock { state -> Bool? in
      if state.shutdownNotified {
        return true
      }
      // Only a bare cancel() — silent teardown with no pipeline — resolves
      // waiters with false. requestShutdown() cancels before running the
      // pipeline, so a waiter arriving in that window must not take the
      // false fast path; it waits for notifyShutdown() like any other.
      if state.cancelled && !state.shutdownRequested {
        return false
      }
      state.shutdownWaiters.append((id, continuation))
      if let timeout {
        let host = self
        let deadline =
          DispatchTime.now()
          + Double(timeout.components.seconds)
          + Double(timeout.components.attoseconds) * 1e-18
        DispatchQueue.global().asyncAfter(deadline: deadline) {
          host.cancelShutdownWaiter(id: id)
        }
      }
      return nil
    }
    if let immediateResult {
      continuation.resume(returning: immediateResult)
    }
  }

  private func cancelShutdownWaiter(id: UUID) {
    let waiter = state.withLock { state in
      state.shutdownWaiters.firstIndex(where: { $0.id == id }).map {
        state.shutdownWaiters.remove(at: $0)
      }
    }
    waiter?.continuation.resume(returning: false)
  }

  private func notifyShutdown() {
    let waiters = state.withLock { state in
      state.shutdownNotified = true
      let waiters = state.shutdownWaiters
      state.shutdownWaiters.removeAll()
      return waiters
    }
    for waiter in waiters {
      waiter.continuation.resume(returning: true)
    }
  }

  /// Silently cancels every accepted peer and closes the host to new ones
  /// without running the shutdown pipeline. Also runs from `deinit`. Any
  /// pending `waitForShutdown` waiter is released with `false` unless shutdown
  /// was already requested. Cancellation is terminal; later requests are no-ops.
  /// Peers arriving after cancellation are
  /// rejected through the standard path (`didRejectPeer` with a nil error).
  public func cancel() {
    let (channels, waiters, cancelOwner) = state.withLock { state in
      let cancelOwner = !state.cancelled && !state.shutdownRequested
      state.cancelled = true
      let channels = Array(state.channels.values)
      state.channels.removeAll()
      // Detach exactly the waiters owned by this bare cancellation. A later
      // shutdown request and its new waiters cannot be drained by this call.
      let waiters = state.shutdownRequested ? [] : state.shutdownWaiters
      if !state.shutdownRequested { state.shutdownWaiters.removeAll() }
      return (channels, waiters, cancelOwner)
    }
    if cancelOwner { managedCancel?() }
    for waiter in waiters {
      waiter.continuation.resume(returning: false)
    }
    for channel in channels {
      channel.cancel()
    }
  }
}
