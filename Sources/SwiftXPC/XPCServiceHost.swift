// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// Channel-level lifecycle hooks for an `XPCServiceHost` — deliberately
/// free of any actor machinery, so plain XPC services and actor services
/// share one delegate vocabulary. Every requirement has a default
/// implementation; state only what you customize.
///
/// Hooks fire from arbitrary threads: peer hooks on XPC event queues (or the
/// accepting thread), `serviceWillShutdown` on the thread that drove the
/// shutdown. Conformance requires `Sendable`; keep shared state behind a
/// lock.
///
/// The hooks are backend-agnostic: `peer.channel` is the accepted channel
/// (C or session backend), and the identity properties (`pid`/`euid`/…) are
/// nil on session-backed peers — the session model has no counterpart
/// accessors, so identity-based audit is a C-backend capability.
public protocol XPCServiceDelegate: Sendable {

  init()
  /// Kernel-enforced code signing requirement installed on every peer
  /// *before activation*. Read once per accepted peer, so class-type
  /// conformers may vary it between peers. A requirement that cannot be
  /// installed (including "the session backend cannot validate peers",
  /// which fails closed with `ENOTSUP`) rejects the peer and reports the
  /// error to `didRejectPeer(_:error:)`: enforcement never silently
  /// degrades to none.
  var peerCodeSigningRequirement: String? { get }

  /// Audit window for each incoming peer, invoked after the requirement is
  /// installed and still *before activation* — inspect `peer.pid` /
  /// `peer.euid` here (C backend only; nil on session peers). Peers
  /// arriving after `requestShutdown()` are rejected before this hook runs.
  /// It may install a requirement via the `setPeer*Requirement` family on
  /// `peer.connection` (C backend only), but a connection accepts at most
  /// one member of that family (libxpc traps on a second install), so when
  /// `peerCodeSigningRequirement` is set this hook must not install
  /// another. Returning `false` rejects the peer; throwing rejects the peer
  /// and reports the error to `didRejectPeer(_:error:)`.
  func shouldAcceptPeer(_ peer: XPCPeerContext) throws -> Bool

  /// Invoked once a peer is accepted (bound to the service, before
  /// activation).
  func didAcceptPeer(_ peer: XPCPeerContext)

  /// Invoked when an accepted peer disconnects — including peers dropped by
  /// XPC for failing a code signing requirement at activation. The channel
  /// is already down at this point; only identity inspection is meaningful.
  func peerDidEnd(_ peer: XPCPeerContext)

  /// Invoked when a peer is rejected before ever being accepted:
  /// `shouldAcceptPeer(_:)` returned `false` (error is `nil`), it threw, the
  /// peer handler threw, the code signing requirement could not be
  /// installed (including the session backend's fail-closed `ENOTSUP`), or
  /// the host already shut down or was cancelled (error is `nil`). The
  /// channel is already cancelled; only identity inspection is meaningful.
  func didRejectPeer(_ peer: XPCPeerContext, error: (any Error)?)

  /// Invoked by a hosted entry point once the host exists, before the event
  /// loop starts — retain `host` here to reach `requestShutdown()` from
  /// outside the accepted peers (e.g. a signal handler). Runs on the main
  /// thread. Standalone hosts never fire it; the owner already holds the
  /// reference.
  func serviceWillStart(host: XPCServiceHost)

  /// Invoked exactly once after a cooperative shutdown has initiated
  /// teardown of every accepted peer, on the thread that drove it. Peer
  /// cancellation is asynchronous, so `peerDidEnd` for those peers may
  /// arrive after this hook. Whether the process then dies is launchd's
  /// decision (on-demand reaping) or the hosting entry point's (which
  /// installs the shutdown completion); this hook is only the notification.
  func serviceWillShutdown()
}

extension XPCServiceDelegate {
  public var peerCodeSigningRequirement: String? { nil }

  public func shouldAcceptPeer(_ peer: XPCPeerContext) throws -> Bool { true }

  public func didAcceptPeer(_ peer: XPCPeerContext) {}

  public func peerDidEnd(_ peer: XPCPeerContext) {}

  public func didRejectPeer(_ peer: XPCPeerContext, error: (any Error)?) {}

  public func serviceWillStart(host: XPCServiceHost) {}

  public func serviceWillShutdown() {}
}

/// A closure-based `XPCServiceDelegate` whose fields all default to
/// "use the protocol default", so a service states only what it customizes.
/// Closure properties mirror the delegate members they override; a `nil`
/// closure falls through to the `XPCServiceDelegate` default.
public struct XPCServiceConfiguration: XPCServiceDelegate {
  /// See `XPCServiceDelegate.peerCodeSigningRequirement`.
  public let peerCodeSigningRequirement: String?

  /// See `XPCServiceDelegate.shouldAcceptPeer(_:)`.
  public let shouldAccept: (@Sendable (XPCPeerContext) throws -> Bool)?

  /// See `XPCServiceDelegate.didAcceptPeer(_:)`.
  public let onPeerAccept: (@Sendable (XPCPeerContext) -> Void)?

  /// See `XPCServiceDelegate.peerDidEnd(_:)`.
  public let onPeerEnd: (@Sendable (XPCPeerContext) -> Void)?

  /// See `XPCServiceDelegate.didRejectPeer(_:error:)`.
  public let onPeerReject: (@Sendable (XPCPeerContext, (any Error)?) -> Void)?

  /// See `XPCServiceDelegate.serviceWillStart(host:)`.
  public let onStart: (@Sendable (XPCServiceHost) -> Void)?

  /// See `XPCServiceDelegate.serviceWillShutdown()`.
  public let onShutdown: (@Sendable () -> Void)?

  /// - Parameters:
  ///   - peerCodeSigningRequirement: `nil` installs nothing.
  ///   - shouldAccept: `nil` accepts every peer.
  public init(
    peerCodeSigningRequirement: String? = nil,
    shouldAccept: (@Sendable (XPCPeerContext) throws -> Bool)? = nil,
    onPeerAccept: (@Sendable (XPCPeerContext) -> Void)? = nil,
    onPeerEnd: (@Sendable (XPCPeerContext) -> Void)? = nil,
    onPeerReject: (@Sendable (XPCPeerContext, (any Error)?) -> Void)? = nil,
    onStart: (@Sendable (XPCServiceHost) -> Void)? = nil,
    onShutdown: (@Sendable () -> Void)? = nil
  ) {
    self.peerCodeSigningRequirement = peerCodeSigningRequirement
    self.shouldAccept = shouldAccept
    self.onPeerAccept = onPeerAccept
    self.onPeerEnd = onPeerEnd
    self.onPeerReject = onPeerReject
    self.onStart = onStart
    self.onShutdown = onShutdown
  }

  public init() {
    self.init(peerCodeSigningRequirement: nil)
  }

  public func shouldAcceptPeer(_ peer: XPCPeerContext) throws -> Bool {
    guard let shouldAccept else { return true }
    return try shouldAccept(peer)
  }

  public func didAcceptPeer(_ peer: XPCPeerContext) {
    onPeerAccept?(peer)
  }

  public func peerDidEnd(_ peer: XPCPeerContext) {
    onPeerEnd?(peer)
  }

  public func didRejectPeer(_ peer: XPCPeerContext, error: (any Error)?) {
    onPeerReject?(peer, error)
  }

  public func serviceWillStart(host: XPCServiceHost) {
    onStart?(host)
  }

  public func serviceWillShutdown() {
    onShutdown?()
  }
}

/// Channel-lifecycle plumbing for an XPC service: channel bookkeeping, the
/// pre-activation audit window, rejection paths, and the cooperative
/// shutdown pipeline — over any `XPCMessageChannel` backend. Actor-free —
/// an actor runtime layers on top by installing a `peerHandler` that binds
/// accepted peers, exactly as `DistributedXPC`'s `XPCServiceHost(_:_:eventLog:)`
/// initializer does.
///
/// Lifecycle of an accepted peer: requirement install →
/// `shouldAcceptPeer` → `peerHandler` (wire message routing) →
/// `didAcceptPeer` → bookkeeping → activation. Rejections run before any of
/// that and end in `didRejectPeer(_:error:)` on an already-cancelled
/// channel.
///
/// The one backend-specific window is the accept decision point: C-backend
/// channels arrive *before activation* (the host audits, then activates);
/// session-backend channels were already accepted inside the listener
/// callback, so a host rejection cancels the live channel. Everything
/// downstream — hooks, requirement enforcement (fail-closed on the session
/// backend), bookkeeping, shutdown pipeline — is backend-agnostic.
///
/// Whether the process retires when the service shuts down is launchd's
/// decision (on-demand reaping) or the hosting entry point's
/// (`setShutdownCompletion`); the host itself never exits the process.
public final class XPCServiceHost: Sendable {
  struct State {
    var channels: [UUID: any XPCMessageChannel] = [:]
    var cancelled = false
    var shutdownRequested = false
  }

  private let state = Mutex(State())
  private let delegate: any XPCServiceDelegate
  private let eventLog: XPCServiceEventLog?
  private let peerHandler = Mutex<@Sendable (any XPCMessageChannel) throws -> Void>({ _ in })
  /// Installed by a hosting entry point; runs after
  /// `delegate.serviceWillShutdown()` on the thread that drove the shutdown.
  private let shutdownCompletion = Mutex<@Sendable () -> Void>({})
  private struct ShutdownState {
    var notified = false
    var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
  }

  private let shutdownState = Mutex(ShutdownState())

  /// - Parameters:
  ///   - delegate: the channel-lifecycle customization.
  ///   - eventLog: when non-nil, the host records every delegate-hook
  ///     invocation into it, in invocation order — the basis for hook
  ///     assertions in tests.
  public init(
    _ delegate: some XPCServiceDelegate,
    eventLog: XPCServiceEventLog? = nil
  ) {
    self.delegate = delegate
    self.eventLog = eventLog
  }

  private func record(_ kind: XPCServiceEvent.Kind, error: (any Error)? = nil) {
    eventLog?.append(kind, error: error)
  }

  deinit { cancel() }

  /// Installs the message-routing step for accepted peers — invoked for
  /// each audited peer *before activation* and before `didAcceptPeer`.
  /// Wire event handlers or bind service state here; the host activates
  /// the channel. Throwing rejects the peer: it is reported to
  /// `didRejectPeer(_:error:)` on an already-cancelled channel. Must be
  /// installed before the host starts accepting; defaults to a no-op for
  /// delegates that manage peers purely through the hooks.
  public func setPeerHandler(
    _ handler: @escaping @Sendable (any XPCMessageChannel) throws -> Void
  ) {
    peerHandler.withLock { $0 = handler }
  }

  /// Installs the hosting layer's post-shutdown step — the explicit
  /// process-retirement control (e.g. `exit(0)` under a hosted entry
  /// point). Runs after `serviceWillShutdown()`, on the shutdown-driving
  /// thread. Without it, a cooperative shutdown only tears the peers down.
  public func setShutdownCompletion(_ completion: @escaping @Sendable () -> Void) {
    shutdownCompletion.withLock { $0 = completion }
  }

  /// Audits, accepts, and bookkeeps one incoming peer channel. The hosted
  /// entry points (`xpcMain`, `xpcSessionMain`) feed this for each incoming
  /// peer; on the C backend, feeders filter listener error events and only
  /// forward real peer channels.
  public func accept(_ channel: any XPCMessageChannel) {
    let peer = XPCPeerContext.make(channel)

    func reject(_ error: (any Error)?) {
      // Reject without releasing an inactive connection (libxpc misuse):
      // install a no-op handler, activate first, then cancel so the peer
      // observes invalidation.
      channel.setIncomingHandler { _ in }
      channel.activate()
      channel.cancel()
      record(.didRejectPeer, error: error)
      delegate.didRejectPeer(peer, error: error)
    }

    // A cancelled host takes no new peers: reject before the audit window,
    // like a post-shutdown peer.
    if state.withLock({ $0.shutdownRequested || $0.cancelled }) {
      return reject(nil)
    }

    if let requirement = delegate.peerCodeSigningRequirement {
      do {
        // Fail-closed on the session backend: applying a requirement throws
        // ENOTSUP instead of silently hosting unvalidated.
        try channel.applyPeerCodeSigningRequirement(requirement)
      } catch {
        return reject(error)
      }
    }
    record(.shouldAcceptPeer)
    do {
      guard try delegate.shouldAcceptPeer(peer) else { return reject(nil) }
    } catch {
      return reject(error)
    }
    do {
      try peerHandler.withLock { $0 }(channel)
    } catch {
      return reject(error)
    }
    record(.didAcceptPeer)
    delegate.didAcceptPeer(peer)

    let key = UUID()
    channel.addInvalidationHandler { [weak self] in
      self?.record(.peerDidEnd)
      self?.delegate.peerDidEnd(peer)
      let removed = self?.state.withLock { $0.channels.removeValue(forKey: key) }
      withExtendedLifetime(removed) {}
    }
    // A peer that activates but then fails the kernel-level requirement
    // delivers XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT; cancel drives the
    // invalidation chain above. C backend only: the session backend has no
    // post-activation requirement events.
    if let connection = peer.connection {
      connection.addPeerCodeSigningErrorHandler {
        connection.cancel()
      }
    }
    let accepted = state.withLock { state -> Bool in
      guard !state.cancelled else { return false }
      state.channels[key] = channel
      // Activate inside the critical section: a concurrent cancel() removes
      // channels and cancels them outside the lock, and it must never
      // observe a registered-but-never-activated channel — libxpc gives
      // cancelling an unactivated connection no defined behavior (the
      // reject path above deliberately activates first for that reason).
      channel.activate()
      return true
    }
    if !accepted {
      channel.activate()
      channel.cancel()
    }
  }

  /// Immediately tears every accepted peer down and closes the host to new
  /// peers, then runs the cooperative shutdown pipeline:
  /// `serviceWillShutdown()` followed by the shutdown completion (when one
  /// is installed). In-flight invocations are not drained. Idempotent:
  /// later calls return without re-running any of it.
  public func requestShutdown() {
    let first = state.withLock { state -> Bool in
      if state.shutdownRequested { return false }
      state.shutdownRequested = true
      return true
    }
    guard first else { return }
    cancel()
    record(.serviceWillShutdown)
    delegate.serviceWillShutdown()
    let completion = shutdownCompletion.withLock { $0 }
    completion()
    notifyShutdown()
  }

  /// Deterministically waits until a cooperative shutdown has run its
  /// pipeline and returns `true`. Returns immediately when the host already
  /// shut down; returns `false` when `timeout` elapses first or when the
  /// host was cancelled without a shutdown request (a cancelled host never
  /// runs the pipeline). A waiter arriving while the pipeline is mid-flight
  /// — after cancellation, before the hook and completion have finished —
  /// resolves with `true` once the pipeline completes. Never polls.
  public func expectShutdown(timeout: Duration? = nil) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      insertShutdownWaiter(id: UUID(), continuation: cont, timeout: timeout)
    }
  }

  private func insertShutdownWaiter(
    id: UUID,
    continuation: CheckedContinuation<Bool, Never>,
    timeout: Duration?
  ) {
    let immediateResult = shutdownState.withLock { shutdown -> Bool? in
      if shutdown.notified {
        return true
      }
      // Only a bare cancel() — silent teardown with no pipeline — resolves
      // waiters with false. requestShutdown() cancels before running the
      // pipeline, so a waiter arriving in that window must not take the
      // false fast path; it waits for notifyShutdown() like any other.
      let (cancelled, requested) = state.withLock { ($0.cancelled, $0.shutdownRequested) }
      if cancelled && !requested {
        return false
      }
      shutdown.waiters.append((id, continuation))
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

  private func cancelShutdownWaiters(resuming value: Bool) {
    let waiters = shutdownState.withLock { shutdown in
      let waiters = shutdown.waiters
      shutdown.waiters.removeAll()
      return waiters
    }
    for waiter in waiters {
      waiter.continuation.resume(returning: value)
    }
  }

  private func cancelShutdownWaiter(id: UUID) {
    let waiter = shutdownState.withLock { shutdown in
      shutdown.waiters.firstIndex(where: { $0.id == id }).map {
        shutdown.waiters.remove(at: $0)
      }
    }
    waiter?.continuation.resume(returning: false)
  }

  private func notifyShutdown() {
    let waiters = shutdownState.withLock { shutdown in
      shutdown.notified = true
      let waiters = shutdown.waiters
      shutdown.waiters.removeAll()
      return waiters
    }
    for waiter in waiters {
      waiter.continuation.resume(returning: true)
    }
  }

  /// Silently cancels every accepted peer and closes the host to new ones
  /// without running the shutdown pipeline. Also runs from `deinit`. Any
  /// pending `expectShutdown` waiter is released with `false`: a cancelled
  /// host never runs the pipeline. Peers arriving after cancellation are
  /// rejected through the standard path (`didRejectPeer` with a nil error).
  public func cancel() {
    let channels = state.withLock { state -> [any XPCMessageChannel] in
      state.cancelled = true
      let channels = Array(state.channels.values)
      state.channels.removeAll()
      return channels
    }
    for channel in channels {
      channel.cancel()
    }
    // requestShutdown() drives the shutdown waiters itself (they resolve
    // true after the pipeline runs); a bare cancel() — silent teardown —
    // resolves them with false instead.
    let requested = state.withLock { $0.shutdownRequested }
    if !requested {
      cancelShutdownWaiters(resuming: false)
    }
  }
}

extension XPCServiceDelegate {
  /// Runs the XPC service event loop with `Self` as the delegate — the
  /// `@main` entry point for a delegate type constructible with no
  /// arguments. Never returns; the hosted service *is* the process, so a
  /// cooperative shutdown exits it.
  ///
  /// The default peer handler ignores incoming traffic: a plain service
  /// that should respond to messages installs its routing from
  /// `serviceWillStart(host:)` via `host.setPeerHandler(...)`.
  @MainActor
  public static func main() {
    let delegate = Self()
    let host = XPCServiceHost(delegate)
    // The hosted service *is* the process: retire it right after the
    // delegate's shutdown hook has run.
    host.setShutdownCompletion { exit(0) }
    delegate.serviceWillStart(host: host)
    xpcMain { connection in host.accept(connection) }
  }
}
