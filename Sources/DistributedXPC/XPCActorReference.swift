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

@available(macOS 15, *)
public protocol XPCActorReferenceConvertible: DistributedActor, XPCMarshal
where ActorSystem == XPCDistributedActorSystem, ID == XPCActorID {}

@available(macOS 15, *)
public enum XPCActorReferenceCodec {
  public typealias Encoded = XPCObject
  public typealias Failure = XPCMarshalError

  public static func encode<Act>(localActor actor: Act) throws(Failure) -> Encoded
  where Act: XPCActorReferenceConvertible {
    try actor.actorSystem.export(actor)
  }

  public static func decode<Act>(
    _ actorType: Act.Type, from object: Encoded
  ) throws(Failure) -> Act
  where Act: XPCActorReferenceConvertible {
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
      return try Act.resolve(id: reference.actorID, using: system)
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

@available(macOS 15, *)
final class XPCActorExportSession: @unchecked Sendable {
  let id: UUID
  let actorID: XPCActorID
  let listener: XPCConnection
  private struct State {
    var peers: [PeerBox] = []
    var cancelled = false
  }
  private let state = Mutex(State())

  init(id: UUID, actorID: XPCActorID, listener: XPCConnection) {
    self.id = id
    self.actorID = actorID
    self.listener = listener
  }

  func accept(_ peer: PeerBox) -> Bool {
    state.withLock {
      guard !$0.cancelled else { return false }
      $0.peers.append(peer)
      return true
    }
  }

  func drop(peerID: UUID) {
    state.withLock { $0.peers.removeAll { $0.id == peerID } }
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
@available(macOS 15, *)
final class PeerBox: @unchecked Sendable {
  let id = UUID()
  let connection: XPCConnection

  init(_ connection: XPCConnection) {
    self.connection = connection
  }
}

@available(macOS 15, *)
extension XPCDistributedActorSystem {
  func export<Act>(_ actor: Act) throws(XPCMarshalError) -> XPCObject
  where Act: XPCActorReferenceConvertible {
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
    throw .remoteActorExportUnsupported(String(describing: Act.self))
  }

  private func mintExportSession<Act>(for actor: Act) throws(XPCMarshalError) -> XPCObject
  where Act: XPCActorReferenceConvertible {
    let listener = XPCConnection(name: nil)
    let sessionID = UUID()
    let session = XPCActorExportSession(id: sessionID, actorID: actor.id, listener: listener)
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
