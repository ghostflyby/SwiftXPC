// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization

/// Marks a concrete distributed actor as the bootstrap entry point of an
/// XPC service: every accepted peer channel serves one instance of this
/// actor under `XPCActorID.root`. Clients obtain it via
/// `connect(toService:)` / `connect(using:)`.
@available(macOS 15, *)
public protocol XPCRootActor: XPCExportableActor,
  XPCDistributedTargetMetadataProviding
{
  init(actorSystem: XPCDistributedActorSystem)
}

@available(macOS 15, *)
public final class XPCRootActorServer<Root>: Sendable
where Root: XPCRootActor {
  private final class Session: @unchecked Sendable {
    /// Per-session systems exist only for plain (non-`XPCServiceExit`)
    /// roots; singleton sessions carry no system of their own.
    let system: XPCDistributedActorSystem?
    /// Keeps the per-session root alive for the session's lifetime; its
    /// release drives the system's actor-reclamation cascade.
    let root: Root?
    let peerConnection: XPCConnection

    init(
      peerConnection: XPCConnection,
      system: XPCDistributedActorSystem?,
      root: Root?
    ) {
      self.peerConnection = peerConnection
      self.system = system
      self.root = root
    }
  }

  private struct State {
    var sessions: [UUID: Session] = [:]
    var cancelled = false
    var shutdownRequested = false
    /// Arms the `XPCServiceExit` idle-exit check: a service that never
    /// accepted a session never exits.
    var everAccepted = false
  }
  private let state = Mutex(State())
  private let delegate: any XPCServiceDelegate<Root>
  /// Installed by the hosted `xpcMain` entry point; runs after
  /// `delegate.serviceWillShutdown()` on the thread that drove the shutdown.
  /// Empty for standalone servers, which never own a process lifetime.
  private let shutdownCompletion = Mutex<@Sendable () -> Void>({})

  /// - Parameters:
  ///   - rootType: the concrete root actor type served on every accepted peer.
  ///   - delegate: the service customization; see `XPCServiceDelegate` for
  ///     the per-hook semantics (pre-activation audit window, fail-closed
  ///     `peerCodeSigningRequirement`, and the cooperative shutdown
  ///     pipeline). Defaults to a plain `XPCServiceConfiguration`, i.e. an
  ///     accept-everything service with no side hooks.
  public init(
    _ rootType: Root.Type = Root.self,
    _ delegate: any XPCServiceDelegate<Root> = XPCServiceConfiguration<Root>()
  ) {
    self.delegate = delegate
  }

  deinit { cancel() }

  /// Immediately tears every live session down and closes the service to new
  /// peers. In-flight invocations are not drained: peers observe their
  /// channels going down (root proxies report `.disconnected` or thrown
  /// `.invalid`), which is what launchd's on-demand reaping needs to retire
  /// the process. Idempotent: later calls return without re-cancelling or
  /// re-firing `delegate.serviceWillShutdown()`.
  ///
  /// Under the hosted `xpcMain` entry point, this is the cooperative
  /// *process* shutdown
  /// path: `serviceWillShutdown()` runs and the process exits. A standalone
  /// server only tears its sessions down; the caller owns the process.
  ///
  /// For a drain-with-grace variant, gate the call on your own in-flight
  /// accounting before invoking this.
  public func requestShutdown() {
    let first = state.withLock { state -> Bool in
      if state.shutdownRequested { return false }
      state.shutdownRequested = true
      return true
    }
    guard first else { return }
    cancel()
    finishShutdown()
  }

  /// Installs the hosting layer's post-shutdown step — under `xpcMain`,
  /// `exit(0)`. Internal: process lifetime is hosting's business, not part
  /// of the delegate or server API.
  func setShutdownCompletion(_ completion: @escaping @Sendable () -> Void) {
    shutdownCompletion.withLock { $0 = completion }
  }

  private func finishShutdown() {
    delegate.serviceWillShutdown()
    shutdownCompletion.withLock { $0 }()
  }

  public func cancel() {
    let sessions = state.withLock { state in
      state.cancelled = true
      let sessions = state.sessions
      state.sessions.removeAll()
      return sessions
    }
    for session in sessions.values {
      session.peerConnection.cancel()
      if let system = session.system {
        system.connection.cancel()
        system.invalidate()
      }
    }
  }

  public func accept(_ connection: XPCConnection) {
    // xpcMain forwards every listener event, including error objects for the
    // listener itself; only real peer connections bootstrap a root session.
    guard connection.isConnectionObject else { return }

    func reject(_ error: (any Error)?) {
      // Reject without releasing an inactive connection (libxpc misuse):
      // activate first, then cancel so the peer observes invalidation.
      connection.setEventHandler { _ in }
      connection.activate()
      connection.cancel()
      delegate.didRejectPeer(connection, error: error)
    }

    if state.withLock({ $0.shutdownRequested }) {
      return reject(nil)
    }

    if let requirement = delegate.peerCodeSigningRequirement {
      do {
        try connection.setPeerCodeSigningRequirement(requirement)
      } catch {
        return reject(error)
      }
    }
    do {
      guard try delegate.shouldAcceptPeer(connection) else { return reject(nil) }
    } catch {
      return reject(error)
    }
    if let exitType = Root.self as? any XPCServiceExit.Type {
      return acceptExitSession(connection, exitType: exitType)
    }
    let system = XPCDistributedActorSystem(connection: connection, ownsConnection: true)
    // Actors of this session reach the cooperative shutdown path through
    // their own system; a weak reference avoids a server <-> system cycle.
    system.setServiceShutdownHandler { [weak self] in self?.requestShutdown() }
    system.reserveRootID()
    let root = delegate.makeRoot(for: system)
    system.bind(connection, to: root)

    let key = UUID()
    let session = Session(peerConnection: connection, system: system, root: root)
    delegate.didAcceptPeer(connection)
    connection.addInvalidationHandler { [weak self] in
      self?.delegate.peerDidEnd(connection)
      let removed = self?.state.withLock { $0.sessions.removeValue(forKey: key) }
      withExtendedLifetime(removed) {}
    }
    // A peer that activates but then fails the kernel-level requirement
    // delivers XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT. bind() has replaced
    // the generic event handler, so without this dedicated handler the error
    // object would be swallowed by the message pump and the dead connection
    // would linger; cancel drives the invalidation chain above.
    connection.addPeerCodeSigningErrorHandler {
      connection.cancel()
    }
    let accepted = state.withLock { state in
      guard !state.cancelled else { return false }
      state.sessions[key] = session
      return true
    }
    connection.activate()
    if !accepted {
      connection.cancel()
      system.invalidate()
    }
  }

  /// Bootstraps a peer for `XPCServiceExit` roots: every peer binds to the
  /// process-wide singleton hosted on the long-lived service host system;
  /// there is no per-session system.
  private func acceptExitSession<E: XPCServiceExit>(
    _ connection: XPCConnection,
    exitType: E.Type
  ) {
    let host = XPCDistributedActorSystem.serviceHost
    // The singleton rides `.root`: reserve it before the first `shared`
    // access so its lazy creation assigns the reserved identity (one
    // `XPCServiceExit` root type per process).
    host.reserveRootID()
    host.setServiceShutdownHandler { [weak self] in self?.requestShutdown() }
    host.setExportDrainHandler { [weak self] in self?.maybeIdleExit() }
    // Programming-error guard: if anything else on the service host consumed
    // the `.root` identity before the singleton was created, refuse the peer
    // instead of silently misrouting every call addressed to `.root`.
    let root = exitType.shared
    guard root.id == .root else {
      connection.setEventHandler { _ in }
      connection.activate()
      connection.cancel()
      delegate.didRejectPeer(connection, error: XPCDispatchError.unknownActor(.root))
      return
    }

    let key = UUID()
    let session = Session(peerConnection: connection, system: nil, root: nil)
    delegate.didAcceptPeer(connection)
    connection.addInvalidationHandler { [weak self] in
      self?.delegate.peerDidEnd(connection)
      let idleCandidate =
        self?.state.withLock { state -> Bool in
          state.sessions.removeValue(forKey: key)
          return state.everAccepted && state.sessions.isEmpty && !state.shutdownRequested
        } ?? false
      if idleCandidate {
        self?.maybeIdleExit()
      }
    }
    // A peer that activates but then fails the kernel-level requirement
    // delivers XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT; cancel drives the
    // invalidation chain above.
    connection.addPeerCodeSigningErrorHandler {
      connection.cancel()
    }
    let accepted = state.withLock { state in
      guard !state.cancelled else { return false }
      state.everAccepted = true
      state.sessions[key] = session
      return true
    }
    host.bind(connection, to: root)
    connection.activate()
    if !accepted {
      connection.cancel()
    }
  }

  /// Idle exit for `XPCServiceExit` roots: once the first connection armed
  /// the check, zero accepted sessions and zero live exported child channels
  /// mean zero remote references — run the cooperative shutdown pipeline
  /// (`serviceWillShutdown`, and the process exit under a hosted
  /// `xpcMain`).
  ///
  /// Handed-out-but-never-dialed export sessions count as live (they are
  /// in-flight references), so they block the exit; the only residual race is
  /// the session-registration micro-window inside `mintExportSession`, where
  /// an in-flight export fails cleanly via the registration guard.
  /// Idempotent, and never fires on an explicitly cancelled server.
  private func maybeIdleExit() {
    guard Root.self is any XPCServiceExit.Type else { return }
    guard !XPCDistributedActorSystem.serviceHost.hasLiveExportPeers else { return }
    let reserved = state.withLock { state -> Bool in
      guard state.everAccepted, state.sessions.isEmpty,
        !state.shutdownRequested, !state.cancelled
      else { return false }
      state.shutdownRequested = true
      return true
    }
    guard reserved else { return }
    cancel()
    finishShutdown()
  }
}

/// Runs the XPC service event loop with default service behavior, serving
/// `rootType` on every accepted peer connection. Never returns. Must run on
/// the main thread.
///
/// Equivalent to `xpcMain(rootType, XPCServiceConfiguration())`: peers are
/// accepted unconditionally unless gated by a `peerCodeSigningRequirement`,
/// and each session constructs `Root(actorSystem:)`. Customize via the
/// delegate overload.
///
/// The hosted entry point only ever runs as a launchd-managed standalone
/// service process (`xpc_main` aborts anywhere else), so a cooperative
/// shutdown unconditionally ends the process: see the delegate overload for
/// the shutdown pipeline. For in-process hosting — tests and embedders —
/// use `xpcTest(_:_:)` or a standalone `XPCRootActorServer`, neither of
/// which ever exits the process.
@available(macOS 15, *)
@MainActor
public func xpcMain<Root>(
  _ rootType: Root.Type
) -> Never where Root: XPCRootActor {
  xpcMain(rootType, XPCServiceConfiguration<Root>())
}

/// Runs the XPC service event loop, serving the delegate's `Root` actor on
/// every accepted peer connection. Never returns. Must run on the main
/// thread.
///
/// The hosted entry point only ever runs as a launchd-managed standalone
/// service process (`xpc_main` aborts anywhere else), so the service *is*
/// the process: a cooperative shutdown
/// (`XPCRootActorServer.requestShutdown()`, or
/// `XPCDistributedActorSystem.requestServiceShutdown()` from actor code)
/// tears every session down, runs `delegate.serviceWillShutdown()`, and
/// then unconditionally exits the process. Peers observe clean disconnects,
/// and together with every client channel going down that is exactly the
/// state launchd's on-demand reaping and any supervisor expect of a retired
/// service. Retain the server from `delegate.serviceWillStart(server:)` to
/// reach `requestShutdown()` from outside the actor graph.
///
/// In-process hosts never exit — build a standalone `XPCRootActorServer` or
/// spawn the `xpcTest(_:_:)` harness instead.
///
/// - Parameters:
///   - rootType: the concrete root actor type served on every accepted peer;
///     drives inference of the delegate's `Root`.
///   - delegate: the service customization, typically an
///     `XPCServiceConfiguration` stating only the customized hooks; see
///     `XPCServiceDelegate` for the per-hook semantics.
@available(macOS 15, *)
@MainActor
public func xpcMain<D: XPCServiceDelegate>(
  _ rootType: D.Root.Type,
  _ delegate: D
) -> Never {
  let server = XPCRootActorServer(rootType, delegate)
  // The hosted service *is* the process: retire it right after the
  // delegate's shutdown hook has run.
  server.setShutdownCompletion { exit(0) }
  delegate.serviceWillStart(server: server)
  return SwiftXPC.xpcMain { connection in server.accept(connection) }
}

@available(macOS 15, *)
extension XPCRootActor {
  /// Connects to a launchd-managed XPC service by mach service name and
  /// resolves its root actor.
  ///
  /// - Parameters:
  ///   - serviceName: the launchd mach service name of the service.
  ///   - peerCodeSigningRequirement: kernel-enforced requirement the service
  ///     must satisfy, installed on the connection before activation. A
  ///     service failing it is dropped by XPC; a requirement that cannot be
  ///     installed makes `connect` throw (fail-closed).
  public static func connect(
    toService serviceName: String,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try connect(
      using: XPCConnection(name: serviceName),
      peerCodeSigningRequirement: peerCodeSigningRequirement)
  }

  /// Connects through an existing connection. Note: only connections to a
  /// *named* mach service re-establish after a service restart; endpoint-based
  /// connections die permanently with the peer.
  ///
  /// `peerCodeSigningRequirement` authenticates the service and must be
  /// installed on a *not-yet-activated* connection. On an already-activated
  /// connection the install reports success but the channel then fails to
  /// establish (hangs or interrupts) — pass a fresh connection.
  public static func connect(
    using connection: XPCConnection,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try connection.applyPeerCodeSigningRequirement(peerCodeSigningRequirement)
    let system = XPCDistributedActorSystem(connection: connection, ownsConnection: true)
    connection.activate()
    return try Self.resolve(id: .root, using: system)
  }
}

@available(macOS 15, *)
extension XPCConnection {
  /// Installs `requirement` on this connection when non-nil. Must run before
  /// activation; an install failure propagates so callers can fail closed.
  func applyPeerCodeSigningRequirement(
    _ requirement: String?
  ) throws(XPCConnection.PeerRequirementError) {
    guard let requirement else { return }
    try setPeerCodeSigningRequirement(requirement)
  }
}
