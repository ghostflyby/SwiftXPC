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
    connection.activate()
    do {
      return try Act.resolve(id: reference.actorID, using: system)
    } catch {
      throw .actorResolutionFailed(String(describing: error))
    }
  }
}

@available(macOS 15, *)
final class XPCActorExportSession: @unchecked Sendable {
  let id: UUID
  let actorID: XPCActorID
  let listener: XPCConnection
  private struct State {
    var peer: XPCConnection?
    var cancelled = false
  }
  private let state = Mutex(State())

  init(id: UUID, actorID: XPCActorID, listener: XPCConnection) {
    self.id = id
    self.actorID = actorID
    self.listener = listener
  }

  func accept(_ connection: XPCConnection) -> Bool {
    state.withLock {
      guard !$0.cancelled, $0.peer == nil else { return false }
      $0.peer = connection
      return true
    }
  }

  func cancel() {
    let peer = state.withLock { state in
      state.cancelled = true
      let peer = state.peer
      state.peer = nil
      return peer
    }
    peer?.cancel()
    listener.cancel()
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
    guard isLocal else {
      throw .remoteActorExportUnsupported(String(describing: Act.self))
    }

    let listener = XPCConnection(name: nil)
    let sessionID = UUID()
    let session = XPCActorExportSession(id: sessionID, actorID: actor.id, listener: listener)
    listener.setEventHandler { [weak self, weak actor, weak session] object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      let peer = XPCConnection(xpc_object: object.xpc_object)
      // Reject extra peers without touching the session: the invalidation
      // handler is only installed after a successful accept, so cancelling a
      // rejected peer can never tear down the serving one.
      guard let self, let actor, let session, session.accept(peer) else {
        peer.setEventHandler { _ in }
        peer.activate()
        peer.cancel()
        return
      }
      peer.addInvalidationHandler { [weak self] in
        self?.removeExportSession(sessionID)
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
