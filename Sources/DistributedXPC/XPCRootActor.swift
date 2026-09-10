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
    let system: XPCDistributedActorSystem
    let root: Root

    init(system: XPCDistributedActorSystem, root: Root) {
      self.system = system
      self.root = root
    }
  }

  private struct State {
    var sessions: [UUID: Session] = [:]
    var cancelled = false
  }
  private let state = Mutex(State())
  private let peerCodeSigningRequirement: String?
  private let shouldAccept: @Sendable (XPCConnection) throws -> Bool
  private let onPeerAccept: @Sendable (XPCConnection) -> Void
  private let onPeerEnd: @Sendable (XPCConnection) -> Void
  private let onPeerReject: @Sendable (XPCConnection, (any Error)?) -> Void

  /// - Parameters:
  ///   - rootType: the concrete root actor type served on every accepted peer.
  ///   - peerCodeSigningRequirement: kernel-enforced code signing requirement
  ///     installed on every peer *before activation* (see
  ///     `XPCConnection.setPeerCodeSigningRequirement`). Peers whose signature
  ///     fails it are dropped by XPC; server-side the failure surfaces as a
  ///     peer end. A requirement that cannot be installed (malformed string,
  ///     unsupported platform) rejects the peer and reports the error to
  ///     `onPeerReject`: enforcement never silently degrades to none.
  ///   - shouldAccept: invoked with each incoming peer connection after the
  ///     requirement is installed, still *before activation* — this is the
  ///     audit window for `connection.pid`/`connection.euid` checks. It may
  ///     install a requirement via the `setPeer*Requirement` family, but a
  ///     connection accepts at most one member of that family (libxpc traps
  ///     on a second install), so when `peerCodeSigningRequirement` is set
  ///     the hook must not install another. Returning `false` rejects the
  ///     peer; throwing rejects the peer and reports the error to
  ///     `onPeerReject`.
  ///   - onPeerAccept: invoked once a peer is bound to a fresh root session
  ///     (before activation). Useful for audit logging via `connection.pid`.
  ///   - onPeerEnd: invoked when an accepted peer disconnects — including
  ///     peers dropped by XPC for failing a code signing requirement at
  ///     activation. The connection object is already invalid at this point;
  ///     only identity inspection is meaningful.
  ///   - onPeerReject: invoked when a peer is rejected before ever being
  ///     accepted: `shouldAccept` returned `false` (error is `nil`),
  ///     `shouldAccept` threw, or the code signing requirement could not be
  ///     installed. The connection is already cancelled; only identity
  ///     inspection is meaningful.
  public init(
    _ rootType: Root.Type = Root.self,
    peerCodeSigningRequirement: String? = nil,
    shouldAccept: (@Sendable (XPCConnection) throws -> Bool)? = nil,
    onPeerAccept: (@Sendable (XPCConnection) -> Void)? = nil,
    onPeerEnd: (@Sendable (XPCConnection) -> Void)? = nil,
    onPeerReject: (@Sendable (XPCConnection, (any Error)?) -> Void)? = nil
  ) {
    self.peerCodeSigningRequirement = peerCodeSigningRequirement
    self.shouldAccept = shouldAccept ?? { _ in true }
    self.onPeerAccept = onPeerAccept ?? { _ in }
    self.onPeerEnd = onPeerEnd ?? { _ in }
    self.onPeerReject = onPeerReject ?? { _, _ in }
  }

  deinit { cancel() }

  public func cancel() {
    let sessions = state.withLock { state in
      state.cancelled = true
      let sessions = state.sessions
      state.sessions.removeAll()
      return sessions
    }
    for session in sessions.values {
      session.system.connection.cancel()
      session.system.invalidate()
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
      onPeerReject(connection, error)
    }

    if let requirement = peerCodeSigningRequirement {
      do {
        try connection.setPeerCodeSigningRequirement(requirement)
      } catch {
        return reject(error)
      }
    }
    do {
      guard try shouldAccept(connection) else { return reject(nil) }
    } catch {
      return reject(error)
    }
    let system = XPCDistributedActorSystem(connection: connection, ownsConnection: true)
    system.reserveRootID()
    let root = Root(actorSystem: system)
    system.bind(connection, to: root)

    let key = UUID()
    let session = Session(system: system, root: root)
    self.onPeerAccept(connection)
    connection.addInvalidationHandler { [weak self] in
      self?.onPeerEnd(connection)
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
}

/// Runs the XPC service event loop, serving `rootType` on every accepted
/// peer connection. Never returns. Must run on the main thread.
///
/// The hook parameters mirror `XPCRootActorServer`'s initializer; see there
/// for the pre-activation audit window and the fail-closed semantics of
/// `peerCodeSigningRequirement`.
@available(macOS 15, *)
@MainActor
public func distributedXPCMain<Root>(
  _ rootType: Root.Type,
  peerCodeSigningRequirement: String? = nil,
  shouldAccept: (@Sendable (XPCConnection) throws -> Bool)? = nil,
  onPeerAccept: (@Sendable (XPCConnection) -> Void)? = nil,
  onPeerEnd: (@Sendable (XPCConnection) -> Void)? = nil,
  onPeerReject: (@Sendable (XPCConnection, (any Error)?) -> Void)? = nil
) -> Never where Root: XPCRootActor {
  let server = XPCRootActorServer(
    rootType,
    peerCodeSigningRequirement: peerCodeSigningRequirement,
    shouldAccept: shouldAccept,
    onPeerAccept: onPeerAccept,
    onPeerEnd: onPeerEnd,
    onPeerReject: onPeerReject)
  return xpcMain { connection in server.accept(connection) }
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
