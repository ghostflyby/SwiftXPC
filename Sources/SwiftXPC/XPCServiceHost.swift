// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// Connection-level lifecycle hooks for an `XPCServiceHost` — deliberately
/// free of any actor machinery, so plain XPC services and actor services
/// share one delegate vocabulary. Every requirement has a default
/// implementation; state only what you customize.
///
/// Hooks fire from arbitrary threads: peer hooks on XPC event queues (or the
/// accepting thread), `serviceWillShutdown` on the thread that drove the
/// shutdown. Conformance requires `Sendable`; keep shared state behind a
/// lock.
public protocol XPCServiceDelegate: Sendable {

  init()
  /// Kernel-enforced code signing requirement installed on every peer
  /// *before activation*. Read once per accepted peer, so class-type
  /// conformers may vary it between peers. A requirement that cannot be
  /// installed rejects the peer and reports the error to
  /// `didRejectPeer(_:error:)`: enforcement never silently degrades to none.
  var peerCodeSigningRequirement: String? { get }

  /// Audit window for each incoming peer, invoked after the requirement is
  /// installed and still *before activation* — inspect
  /// `connection.pid`/`connection.euid` here. Peers arriving after
  /// `requestShutdown()` are rejected before this hook runs. It may install
  /// a requirement via the `setPeer*Requirement` family, but a connection
  /// accepts at most one member of that family (libxpc traps on a second
  /// install), so when `peerCodeSigningRequirement` is set this hook must
  /// not install another. Returning `false` rejects the peer; throwing
  /// rejects the peer and reports the error to `didRejectPeer(_:error:)`.
  func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool

  /// Invoked once a peer is accepted (bound to the service, before
  /// activation).
  func didAcceptPeer(_ connection: XPCConnection)

  /// Invoked when an accepted peer disconnects — including peers dropped by
  /// XPC for failing a code signing requirement at activation. The
  /// connection object is already invalid at this point; only identity
  /// inspection is meaningful.
  func peerDidEnd(_ connection: XPCConnection)

  /// Invoked when a peer is rejected before ever being accepted:
  /// `shouldAcceptPeer(_:)` returned `false` (error is `nil`), it threw, the
  /// peer handler threw, the code signing requirement could not be
  /// installed, or the host already shut down (error is `nil`). The
  /// connection is already cancelled; only identity inspection is
  /// meaningful.
  func didRejectPeer(_ connection: XPCConnection, error: (any Error)?)

  /// Invoked by a hosted entry point once the host exists, before the event
  /// loop starts — retain `host` here to reach `requestShutdown()` from
  /// outside the accepted peers (e.g. a signal handler). Runs on the main
  /// thread. Standalone hosts never fire it; the owner already holds the
  /// reference.
  func serviceWillStart(host: XPCServiceHost)

  /// Invoked exactly once after a cooperative shutdown finished tearing
  /// every accepted peer down, on the thread that drove it. Whether the
  /// process then dies is launchd's decision (on-demand reaping) or the
  /// hosting entry point's (which installs the shutdown completion); this
  /// hook is only the notification.
  func serviceWillShutdown()
}

extension XPCServiceDelegate {
  public var peerCodeSigningRequirement: String? { nil }

  public func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool { true }

  public func didAcceptPeer(_ connection: XPCConnection) {}

  public func peerDidEnd(_ connection: XPCConnection) {}

  public func didRejectPeer(_ connection: XPCConnection, error: (any Error)?) {}

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
  public let shouldAccept: (@Sendable (XPCConnection) throws -> Bool)?

  /// See `XPCServiceDelegate.didAcceptPeer(_:)`.
  public let onPeerAccept: (@Sendable (XPCConnection) -> Void)?

  /// See `XPCServiceDelegate.peerDidEnd(_:)`.
  public let onPeerEnd: (@Sendable (XPCConnection) -> Void)?

  /// See `XPCServiceDelegate.didRejectPeer(_:error:)`.
  public let onPeerReject: (@Sendable (XPCConnection, (any Error)?) -> Void)?

  /// See `XPCServiceDelegate.serviceWillStart(host:)`.
  public let onStart: (@Sendable (XPCServiceHost) -> Void)?

  /// See `XPCServiceDelegate.serviceWillShutdown()`.
  public let onShutdown: (@Sendable () -> Void)?

  /// - Parameters:
  ///   - peerCodeSigningRequirement: `nil` installs nothing.
  ///   - shouldAccept: `nil` accepts every peer.
  public init(
    peerCodeSigningRequirement: String? = nil,
    shouldAccept: (@Sendable (XPCConnection) throws -> Bool)? = nil,
    onPeerAccept: (@Sendable (XPCConnection) -> Void)? = nil,
    onPeerEnd: (@Sendable (XPCConnection) -> Void)? = nil,
    onPeerReject: (@Sendable (XPCConnection, (any Error)?) -> Void)? = nil,
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

  public func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool {
    guard let shouldAccept else { return true }
    return try shouldAccept(connection)
  }

  public func didAcceptPeer(_ connection: XPCConnection) {
    onPeerAccept?(connection)
  }

  public func peerDidEnd(_ connection: XPCConnection) {
    onPeerEnd?(connection)
  }

  public func didRejectPeer(_ connection: XPCConnection, error: (any Error)?) {
    onPeerReject?(connection, error)
  }

  public func serviceWillStart(host: XPCServiceHost) {
    onStart?(host)
  }

  public func serviceWillShutdown() {
    onShutdown?()
  }
}

/// Connection-lifecycle plumbing for an XPC service: session bookkeeping,
/// the pre-activation audit window, rejection paths, and the cooperative
/// shutdown pipeline. Actor-free — an actor runtime layers on top by
/// subclassing and installing a `peerHandler` that binds accepted peers,
/// exactly as `DistributedXPC`'s root-actor server does.
///
/// Lifecycle of an accepted peer: requirement install →
/// `shouldAcceptPeer` → `peerHandler` (wire message routing) →
/// `didAcceptPeer` → bookkeeping → activation. Rejections run before any of
/// that and end in `didRejectPeer(_:error:)` on an already-cancelled
/// connection.
///
/// Whether the process retires when the service shuts down is launchd's
/// decision (on-demand reaping) or the hosting entry point's
/// (`setShutdownCompletion`); the host itself never exits the process.
public final class XPCServiceHost: Sendable {
  final class Session: Sendable {
    let peerConnection: XPCConnection

    init(peerConnection: XPCConnection) {
      self.peerConnection = peerConnection
    }
  }

  struct State {
    var sessions: [UUID: Session] = [:]
    var cancelled = false
    var shutdownRequested = false
  }

  private let state = Mutex(State())
  private let delegate: any XPCServiceDelegate
  private let eventLog: XPCServiceEventLog?
  private let peerHandler = Mutex<@Sendable (XPCConnection) throws -> Void>({ _ in })
  /// Installed by a hosting entry point; runs after
  /// `delegate.serviceWillShutdown()` on the thread that drove the shutdown.
  private let shutdownCompletion = Mutex<@Sendable () -> Void>({})
  private struct ShutdownState {
    var notified = false
    var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
  }

  private let shutdownState = Mutex(ShutdownState())

  /// - Parameters:
  ///   - delegate: the connection-lifecycle customization.
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
  /// the connection. Throwing rejects the peer: it is reported to
  /// `didRejectPeer(_:error:)` on an already-cancelled connection. Must be
  /// installed before the host starts accepting; defaults to a no-op for
  /// delegates that manage peers purely through the hooks.
  public func setPeerHandler(
    _ handler: @escaping @Sendable (XPCConnection) throws -> Void
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

  /// Audits, accepts, and bookkeeps one incoming peer connection. The
  /// hosted entry point (`xpcMain`) feeds this for each incoming peer;
  /// connections that are not peer connection objects (listener error
  /// events) are ignored.
  public func accept(_ connection: XPCConnection) {
    // Listener event handlers forward every event, including error objects
    // for the listener itself; only real peers bootstrap a session.
    guard connection.isConnectionObject else { return }

    func reject(_ error: (any Error)?) {
      // Reject without releasing an inactive connection (libxpc misuse):
      // activate first, then cancel so the peer observes invalidation.
      connection.setEventHandler { _ in }
      connection.activate()
      connection.cancel()
      record(.didRejectPeer, error: error)
      delegate.didRejectPeer(connection, error: error)
    }

    if state.withLock({ $0.shutdownRequested }) {
      return reject(nil)
    }

    // libxpc traps if a message arrives on a connection activated without
    // an event handler. Install the no-op default first; a peerHandler
    // that wires real routing replaces it (exactly like reject() above).
    connection.setEventHandler { _ in }

    if let requirement = delegate.peerCodeSigningRequirement {
      do {
        try connection.setPeerCodeSigningRequirement(requirement)
      } catch {
        return reject(error)
      }
    }
    record(.shouldAcceptPeer)
    do {
      guard try delegate.shouldAcceptPeer(connection) else { return reject(nil) }
    } catch {
      return reject(error)
    }
    do {
      try peerHandler.withLock { $0 }(connection)
    } catch {
      return reject(error)
    }
    record(.didAcceptPeer)
    delegate.didAcceptPeer(connection)

    let key = UUID()
    let session = Session(peerConnection: connection)
    connection.addInvalidationHandler { [weak self] in
      self?.record(.peerDidEnd)
      self?.delegate.peerDidEnd(connection)
      let removed = self?.state.withLock { $0.sessions.removeValue(forKey: key) }
      withExtendedLifetime(removed) {}
    }
    // A peer that activates but then fails the kernel-level requirement
    // delivers XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT; cancel drives the
    // invalidation chain above.
    connection.addPeerCodeSigningErrorHandler {
      connection.cancel()
    }
    let accepted = state.withLock { state -> Bool in
      guard !state.cancelled else { return false }
      state.sessions[key] = session
      return true
    }
    connection.activate()
    if !accepted {
      connection.cancel()
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
  /// host was cancelled (a cancelled host never runs the pipeline). Never
  /// polls.
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
      if shutdown.notified || state.withLock({ $0.cancelled }) {
        return shutdown.notified
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
  /// host never runs the pipeline.
  public func cancel() {
    let sessions = state.withLock { state -> [UUID: Session] in
      state.cancelled = true
      let sessions = state.sessions
      state.sessions.removeAll()
      return sessions
    }
    for session in sessions.values {
      session.peerConnection.cancel()
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
