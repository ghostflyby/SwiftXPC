// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
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
    private let shouldAccept: @Sendable (XPCConnection) -> Bool
    private let onPeerAccept: @Sendable (XPCConnection) -> Void
    private let onPeerEnd: @Sendable (XPCConnection) -> Void

    /// - Parameters:
    ///   - rootType: the concrete root actor type served on every accepted peer.
    ///   - shouldAccept: invoked with each incoming peer connection before any
    ///     session state is created; returning `false` rejects the peer. Use it
    ///     for custom checks such as `connection.pid` or `connection.euid`.
    ///     Kernel-level enforcement belongs in code signing requirements set via
    ///     `XPCConnection.setPeerCodeSigningRequirement` before activation.
    ///   - onPeerAccept: invoked once a peer is bound to a fresh root session
    ///     (before activation). Useful for audit logging via `connection.pid`.
    ///   - onPeerEnd: invoked when an accepted peer disconnects. The connection
    ///     object is already invalid at this point; only identity inspection is
    ///     meaningful.
    public init(
      _ rootType: Root.Type = Root.self,
      shouldAccept: @escaping @Sendable (XPCConnection) -> Bool = { _ in true },
      onPeerAccept: (@Sendable (XPCConnection) -> Void)? = nil,
      onPeerEnd: (@Sendable (XPCConnection) -> Void)? = nil
    ) {
      self.shouldAccept = shouldAccept
      self.onPeerAccept = onPeerAccept ?? { _ in }
      self.onPeerEnd = onPeerEnd ?? { _ in }
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
      guard shouldAccept(connection) else {
        // Reject without releasing an inactive connection (libxpc misuse):
        // activate first, then cancel so the peer observes invalidation.
        connection.setEventHandler { _ in }
        connection.activate()
        connection.cancel()
        return
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

  @available(macOS 15, *)
  @MainActor
  public func distributedXPCMain<Root>(_ rootType: Root.Type) -> Never
  where Root: XPCRootActor {
    let server = XPCRootActorServer(rootType)
    return xpcMain { connection in server.accept(connection) }
  }

  @available(macOS 15, *)
  extension XPCRootActor {
    public static func connect(toService serviceName: String) throws -> Self {
      try connect(using: XPCConnection(name: serviceName))
    }

    public static func connect(using connection: XPCConnection) throws -> Self {
      let system = XPCDistributedActorSystem(connection: connection, ownsConnection: true)
      connection.activate()
      return try Self.resolve(id: .root, using: system)
    }
  }

#endif
