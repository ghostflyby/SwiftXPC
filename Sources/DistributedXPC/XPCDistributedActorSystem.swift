import Dispatch
import Foundation
// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC
import Synchronization
import XPC

/// The `DistributedActorSystem` implementation that carries distributed
/// actor calls over XPC.
///
/// Every inbound XPC channel serves exactly one bound actor: the initial
/// mach service channel serves a root actor (ID `.root`), and each exported
/// actor reference mints its own channel. Outbound calls ride the named
/// connection, which launchd re-establishes transparently after a service
/// restart.
@available(macOS 15, *)
public final class XPCDistributedActorSystem: DistributedActorSystem, Sendable {
  public typealias ActorID = XPCActorID
  public typealias ResultHandler = XPCInvocationResultHandler
  public typealias InvocationEncoder = XPCInvocationEncoder
  public typealias InvocationDecoder = XPCInvocationDecoder
  public typealias SerializationRequirement = XPCMarshal

  let activeActorsLock: Mutex<[ActorID: any DistributedActor]> = Mutex([:])

  private let ids = Atomic<UInt64>(0)
  private let assignedIDsLock: Mutex<Set<ActorID>> = Mutex([])

  private let reservedIDLock: Mutex<ActorID?> = Mutex(nil)

  let exportSessionsLock = Mutex<[UUID: XPCActorExportSession]>([:])
  let importedReferencesLock = Mutex<[XPCActorID: StoredActorReference]>([:])
  let invalidated = Mutex(false)
  private let ownsConnection: Bool
  public let connection: XPCConnection

  public convenience init(connection: XPCConnection) {
    self.init(connection: connection, ownsConnection: false)
  }

  init(connection: XPCConnection, ownsConnection: Bool) {
    self.connection = connection
    self.ownsConnection = ownsConnection
    self.connection.addInvalidationHandler { [weak self] in
      self?.invalidate()
    }
    installEventHandler()
  }

  deinit {
    if ownsConnection { connection.cancel() }
    // Drain sessions and actors before stored properties (and their locks)
    // are destroyed: releasing registered actors later would re-enter
    // resignID on half-destroyed Mutexes.
    invalidate()
  }

  func invalidate() {
    let sessions = invalidated.withLock { invalidated in
      invalidated = true
      let sessions = exportSessionsLock.withLock {
        let sessions = Array($0.values)
        $0.removeAll()
        return sessions
      }
      importedReferencesLock.withLock { $0.removeAll() }
      return sessions
    }
    for session in sessions { session.cancel() }
    // Actor destruction calls resignID, so release registry contents outside its lock.
    let actors = activeActorsLock.withLock { actors in
      let retained = actors
      actors.removeAll()
      return retained
    }
    withExtendedLifetime(actors) {}
  }

  func rememberImported(_ reference: StoredActorReference) {
    invalidated.withLock { invalidated in
      guard !invalidated else { return }
      importedReferencesLock.withLock { $0[reference.actorID] = reference }
    }
  }

  /// Returns the local actor registered under `id`, or nil so the runtime
  /// creates a remote proxy. This is the standard distributed resolution
  /// entry point; see `XPCRootActor.connect` for bootstrap.
  public func resolve<Act>(id: ActorID, as actorType: Act.Type)
    throws -> Act? where Act: DistributedActor
  {
    activeActorsLock.withLock { $0[id] as? Act }
  }

  /// Assigns the next local actor ID (starting at 1), unless a framework
  /// reservation (root bootstrap) is pending.
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
  where Act: DistributedActor {
    if let reserved = reservedIDLock.withLock({
      let r = $0
      $0 = nil
      return r
    }) {
      _ = assignedIDsLock.withLock { $0.insert(reserved) }
      return reserved
    }
    let id = XPCActorID(id: ids.wrappingAdd(1, ordering: .relaxed).newValue)
    _ = assignedIDsLock.withLock { $0.insert(id) }
    return id
  }

  /// Reserves `.root` for the next actor created on this system. Only call
  /// on a freshly created system before any concurrent `assignID` (the
  /// framework does this inside `XPCRootActorServer.accept`).
  func reserveRootID() {
    reservedIDLock.withLock { $0 = .root }
  }

  /// Registers a freshly created local actor under its assigned ID.
  /// Called by the runtime during local actor initialization.
  public func actorReady<Act>(_ actor: Act)
  where Act: DistributedActor, Act.ID == ActorID {
    guard self.assignedIDsLock.withLock({ $0.contains(actor.id) }) else {
      fatalError("Attempted to mark an unknown actor '\(actor.id)' ready")
    }
    let previous = invalidated.withLock { invalidated -> (any DistributedActor)? in
      guard !invalidated else { return nil }
      return self.activeActorsLock.withLock { $0.updateValue(actor, forKey: actor.id) }
    }
    withExtendedLifetime(previous) {}
  }

  /// Removes a local actor and tears down any channels exporting it.
  /// Called by the runtime when a local actor is destroyed.
  public func resignID(_ id: ActorID) {
    _ = self.activeActorsLock.withLock { $0.removeValue(forKey: id) }
    let sessions = self.exportSessionsLock.withLock { exports in
      let matching = exports.filter { $0.value.actorID == id }
      for key in matching.keys { exports.removeValue(forKey: key) }
      return matching.map(\.value)
    }
    for session in sessions { session.cancel() }
  }

  public func makeInvocationEncoder() -> InvocationEncoder { .init() }

  /// Installs the connection's event plumbing. Unbound systems only ever see
  /// lifecycle error objects here (there is no actor to dispatch messages to);
  /// channels serving an actor overwrite this handler via `bind`.
  func installEventHandler() {
    connection.setEventHandler { _ in }
  }

  private func runIncomingHandler(_ operation: @escaping @Sendable () async throws -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task {
      try? await operation()
      done.signal()
    }
    done.wait()
  }

  func bind<Act>(_ connection: XPCConnection, to actor: Act)
  where Act: DistributedActor, Act.ID == ActorID {
    connection.setEventHandler { [weak self, weak actor] object in
      guard let self, let actor else { return }
      self.runIncomingHandler {
        try await self.handleIncomingMessage(object, on: actor)
      }
    }
  }

  func dispatchInvocation<Act>(
    _ message: XPCInvocationMessage, on actor: Act
  ) async throws -> XPCReplyEnvelope
  where Act: DistributedActor, Act.ID == ActorID {
    guard message.actorID == actor.id else {
      throw XPCDispatchError.unknownActor(message.actorID)
    }
    guard message.version == XPCWireProtocol.currentVersion else {
      throw XPCDispatchError.unsupportedProtocolVersion(
        expected: XPCWireProtocol.currentVersion, actual: message.version)
    }

    // Metadata conformance is optional. When present, a non-empty table acts
    // as a method whitelist and supplies typed-throws error decoding for the
    // caller; without it (or with an empty table) dispatch is permissive and
    // unknown targets fail in executeDistributedTarget instead.
    let metadataTable = (type(of: actor) as? any XPCDistributedTargetMetadataProviding.Type)?
      .xpcDistributedTargetMetadata
    if let metadataTable, !metadataTable.isEmpty,
      lookupMetadata(forMethod: message.method, in: metadataTable) == nil
    {
      throw XPCDispatchError.unknownTarget(message.method)
    }
    var decoder = XPCInvocationDecoder(array: message.arguments)
    let replyLock = Mutex<XPCReplyEnvelope?>(nil)
    let resultHandler = XPCInvocationResultHandler { envelope in
      replyLock.withLock { $0 = envelope }
    }
    do {
      try await executeDistributedTarget(
        on: actor, target: message.target,
        invocationDecoder: &decoder, handler: resultHandler)
    } catch let error as any ErrorXPCMarshal {
      throw error
    } catch {
      throw XPCDispatchError.targetExecutionFailed(String(describing: error))
    }
    guard let reply = replyLock.withLock({ $0 }) else {
      throw XPCDispatchError.missingInvocationResult
    }
    return reply
  }

  private func fallbackThrownErrorType<Act, Err>(
    for actorType: Act.Type,
    method: String,
    throwing errorType: Err.Type
  ) throws -> (any ErrorXPCMarshal.Type)?
  where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    if errorType is any ErrorXPCMarshal.Type { return nil }
    guard let metadataProvider = actorType as? any XPCDistributedTargetMetadataProviding.Type
    else { return nil }
    return lookupMetadata(forMethod: method, in: metadataProvider.xpcDistributedTargetMetadata)?
      .thrownErrorType
  }

  func handleIncomingMessage<Act>(_ object: XPCObject, on actor: Act) async throws
  where Act: DistributedActor, Act.ID == ActorID {
    let received = try XPCDictionary.unmarshal(from: object)
    let resultHandler = XPCInvocationResultHandler(received: received)
    do {
      let invocation = try XPCInvocationMessage.unmarshal(from: object)
      let envelope = try await dispatchInvocation(invocation, on: actor)
      try resultHandler.send(envelope)
    } catch let error as any ErrorXPCMarshal {
      try resultHandler.send(
        XPCReplyEnvelope(kind: .throwError, payload: try error.marshal()))
    }
  }

  func decodeRemoteCallReply<Act, Err, Res>(
    _ envelope: XPCReplyEnvelope,
    for actorType: Act.Type,
    target: RemoteCallTarget,
    method: String,
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) throws -> Res
  where
    Act: DistributedActor, Act.ID == ActorID,
    Err: Error, Res: SerializationRequirement
  {
    let fallbackErrorType = try fallbackThrownErrorType(
      for: actorType, method: method, throwing: errorType)
    return try envelope.decodeReturnValue(
      throwing: errorType, returning: returnType, fallbackErrorType: fallbackErrorType)
  }

  func decodeRemoteCallVoidReply<Act, Err>(
    _ envelope: XPCReplyEnvelope,
    for actorType: Act.Type,
    target: RemoteCallTarget,
    method: String,
    throwing errorType: Err.Type
  ) throws
  where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    let fallbackErrorType = try fallbackThrownErrorType(
      for: actorType, method: method, throwing: errorType)
    try envelope.decodeReturnVoid(throwing: errorType, fallbackErrorType: fallbackErrorType)
  }

  /// Sends an invocation over the connection and decodes the reply.
  /// Called by compiler-generated distributed thunks.
  public func remoteCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) async throws -> Res
  where
    Act: DistributedActor, Act.ID == ActorID,
    Err: Error, Res: SerializationRequirement
  {
    let method = parseTargetIdentifier(target.identifier) ?? target.identifier
    let message = XPCInvocationMessage(
      method: method, actorID: actor.id, target: target, arguments: invocation.array)
    let payload = try message.marshal()
    let xpcDict = XPCDictionary(xpc_object: payload.xpc_object)
    let result = try await connection.send(message: xpcDict)
    let envelope = try XPCReplyEnvelope.unmarshal(from: result)
    return try decodeRemoteCallReply(
      envelope, for: Act.self, target: target, method: method,
      throwing: errorType, returning: returnType)
  }

  /// Sends a void invocation over the connection. Called by
  /// compiler-generated distributed thunks.
  public func remoteCallVoid<Act, Err>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type
  ) async throws
  where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    let method = parseTargetIdentifier(target.identifier) ?? target.identifier
    let message = XPCInvocationMessage(
      method: method, actorID: actor.id, target: target, arguments: invocation.array)
    let payload = try message.marshal()
    let xpcDict = XPCDictionary(xpc_object: payload.xpc_object)
    let result = try await connection.send(message: xpcDict)
    let envelope = try XPCReplyEnvelope.unmarshal(from: result)
    try decodeRemoteCallVoidReply(
      envelope, for: Act.self, target: target, method: method, throwing: errorType)
  }
}
