// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization
import XPC

@available(macOS 15, *)
@XPCMarshal
struct XPCActorReferenceWire {
  let version: UInt64
  let actorID: XPCActorID
  let endpoint: XPCObject
}

/// A distributed actor that can cross process boundaries as an XPC actor
/// reference. Applied automatically by `@XPCService`; provides default
/// `marshal()` (export on a fresh channel) and `unmarshal(from:)` (dial the
/// embedded endpoint, resolve a proxy) implementations.
@available(macOS 15, *)
public protocol XPCExportableActor: DistributedActor, XPCMarshal
where ActorSystem == XPCDistributedActorSystem, ID == XPCActorID {}

@available(macOS 15, *)
extension XPCExportableActor {
  /// Exports this local actor as a self-contained XPC actor reference:
  /// `{ version, actorID, endpoint }` on a freshly minted channel.
  public nonisolated func marshal() throws(XPCMarshalError) -> XPCObject {
    try actorSystem.export(self)
  }

  /// Imports an actor reference by dialing the embedded endpoint and resolving
  /// the actor against the fresh channel, yielding a remote proxy.
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    let reference = try XPCActorReferenceWire.unmarshal(from: object)
    guard reference.version == XPCWireProtocol.currentVersion else {
      throw .unsupportedProtocolVersion(
        expected: XPCWireProtocol.currentVersion, actual: reference.version)
    }

    let connection = try XPCConnection.unmarshal(from: reference.endpoint)
    let system = XPCDistributedActorSystem(connection: connection, ownsConnection: true)
    // Remember the wire so this proxy can be forwarded later: re-exporting
    // re-emits the stored endpoint, giving the next receiver its own direct
    // channel to the owning process.
    system.rememberImported(
      StoredActorReference(actorID: reference.actorID, endpoint: reference.endpoint))
    connection.activate()
    do {
      return try Self.resolve(id: reference.actorID, using: system)
    } catch {
      throw .actorResolutionFailed(String(describing: error))
    }
  }
}

/// The retained wire of an imported actor proxy, kept so the proxy can be
/// forwarded to other processes without involving its owning process.
@available(macOS 15, *)
final class StoredActorReference: @unchecked Sendable {
  let actorID: XPCActorID
  private let endpointObject: xpc_object_t

  init(actorID: XPCActorID, endpoint: XPCObject) {
    self.actorID = actorID
    self.endpointObject = xpc_retain(endpoint.xpc_object)
  }

  deinit { xpc_release(endpointObject) }

  var endpoint: XPCObject { XPCObject(xpc_object: endpointObject) }
}

/// One exported-actor endpoint: a fresh anonymous listener plus the peers
/// that dialed it. The listener lives as long as the owning session — until
/// the exported actor is destroyed or the system is invalidated. It is
/// deliberately *not* torn down when the peer list drains: the endpoint may
/// already have been handed to a receiver that has not dialed yet, and an
/// anonymous listener occupies no launchd client connection, so it cannot
/// block on-demand reaping.
@available(macOS 15, *)
final class XPCActorExportSession: @unchecked Sendable {
  let id: UUID
  let actorID: XPCActorID
  let listener: XPCConnection
  /// Invoked when the session transitions to zero live peers. Never invoked
  /// from `cancel()`.
  let onDrained: @Sendable () -> Void
  private struct State {
    var peers: [PeerBox] = []
    var cancelled = false
    var everAcceptedPeer = false
  }
  private let state = Mutex(State())

  init(
    id: UUID,
    actorID: XPCActorID,
    listener: XPCConnection,
    onDrained: @escaping @Sendable () -> Void
  ) {
    self.id = id
    self.actorID = actorID
    self.listener = listener
    self.onDrained = onDrained
  }

  /// Number of live peer channels, for lifecycle introspection.
  var peerCount: Int {
    state.withLock { $0.peers.count }
  }

  /// Zero live peers after having accepted at least one: every remote
  /// reference routed through this session is gone. A session that was
  /// handed out but never dialed is an in-flight wire and never reports
  /// drained.
  var fullyDrained: Bool {
    state.withLock { state in
      state.everAcceptedPeer && state.peers.isEmpty
    }
  }

  func accept(_ peer: PeerBox) -> Bool {
    state.withLock {
      guard !$0.cancelled else { return false }
      $0.everAcceptedPeer = true
      $0.peers.append(peer)
      return true
    }
  }

  func drop(peerID: UUID) {
    // Remove under the lock, release outside: PeerBox deinit cancels the
    // peer, and teardown must never run while `state` is held.
    let (removed, drained) = state.withLock { state -> (PeerBox?, Bool) in
      guard let index = state.peers.firstIndex(where: { $0.id == peerID }) else {
        return (nil, false)
      }
      let removed = state.peers.remove(at: index)
      return (removed, state.peers.isEmpty && !state.cancelled)
    }
    _ = removed
    if drained { onDrained() }
  }

  func cancel() {
    let peers = state.withLock { state in
      state.cancelled = true
      let peers = state.peers
      state.peers = []
      return peers
    }
    for peer in peers { peer.connection.cancel() }
    listener.cancel()
  }
}

/// Identity wrapper so an accepted peer connection can be removed from the
/// session when it dies (XPCConnection is a struct without stable identity).
/// Dropping the box also cancels this side of the channel: when a client
/// releases its imported proxy, its owned system tears the connection down,
/// and this end must close symmetrically instead of lingering half-open.
/// Cancelling an already-dead connection is a no-op.
@available(macOS 15, *)
final class PeerBox: @unchecked Sendable {
  let id = UUID()
  let connection: XPCConnection

  init(_ connection: XPCConnection) {
    self.connection = connection
  }

  deinit { connection.cancel() }
}

@available(macOS 15, *)
extension XPCDistributedActorSystem {
  func export<Act>(_ actor: Act) throws(XPCMarshalError) -> XPCObject
  where Act: XPCExportableActor {
    let isLocal = activeActorsLock.withLock { actors in
      guard let registered = actors[actor.id] as? Act else { return false }
      return registered === actor
    }
    if isLocal {
      return try mintExportSession(for: actor)
    }
    // Forwarding: this actor is an imported proxy, so re-emit its stored
    // endpoint and give the receiver a direct channel to the owning process.
    if let stored = importedReferencesLock.withLock({ $0[actor.id] }) {
      let reference = XPCActorReferenceWire(
        version: XPCWireProtocol.currentVersion,
        actorID: stored.actorID,
        endpoint: stored.endpoint
      )
      return try reference.marshal()
    }
    // Child reclamation may have released the registry entry of a local
    // actor that is still alive (the singleton kept a reference). Re-adopt
    // it; a remote proxy without a stored wire is genuinely unexportable.
    // `__isLocalActor` is the runtime's public locality probe.
    guard __isLocalActor(actor) else {
      throw .remoteActorExportUnsupported(String(describing: Act.self))
    }
    let previous = invalidated.withLock { invalidated -> (any DistributedActor)? in
      guard !invalidated else { return nil }
      return activeActorsLock.withLock { actors in
        actors.updateValue(actor, forKey: actor.id)
      }
    }
    // Release any displaced occupant outside the lock: its deinit calls
    // back into `resignID`, which re-enters `activeActorsLock`.
    withExtendedLifetime(previous) {}
    return try mintExportSession(for: actor)
  }

  private func mintExportSession<Act>(for actor: Act) throws(XPCMarshalError) -> XPCObject
  where Act: XPCExportableActor {
    let listener = XPCConnection(name: nil)
    let sessionID = UUID()
    let actorID = actor.id
    let session = XPCActorExportSession(
      id: sessionID,
      actorID: actorID,
      listener: listener,
      onDrained: { [weak self] in self?.exportSessionDrained(actorID) }
    )
    listener.setEventHandler { [weak self, weak actor, weak session] object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      let peer = XPCConnection(xpc_object: object.xpc_object)
      // A forwarded reference is consumed once per receiver, so the listener
      // serves every peer. Rejections never touch the session: the peer's
      // invalidation handler is installed only after a successful accept.
      guard let self, let actor, let session else {
        peer.setEventHandler { _ in }
        peer.activate()
        peer.cancel()
        return
      }
      let box = PeerBox(peer)
      guard session.accept(box) else {
        peer.setEventHandler { _ in }
        peer.activate()
        peer.cancel()
        return
      }
      peer.addInvalidationHandler { [weak session, weak box] in
        guard let session, let box else { return }
        session.drop(peerID: box.id)
      }
      self.bind(peer, to: actor)
      peer.activate()
    }
    listener.activate()

    let registered = invalidated.withLock { invalidated in
      guard !invalidated else { return false }
      exportSessionsLock.withLock { $0[sessionID] = session }
      return true
    }
    guard registered else {
      session.cancel()
      throw .invalidActorReference("Owning session is invalidated")
    }
    do {
      let reference = XPCActorReferenceWire(
        version: XPCWireProtocol.currentVersion,
        actorID: actor.id,
        endpoint: try listener.marshal()
      )
      return try reference.marshal()
    } catch {
      removeExportSession(sessionID)
      throw error
    }
  }

  private func removeExportSession(_ id: UUID) {
    let session = exportSessionsLock.withLock { $0.removeValue(forKey: id) }
    session?.cancel()
  }
}
