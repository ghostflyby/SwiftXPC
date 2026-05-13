import Dispatch
// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC
import Synchronization

@available(macOS 15, *)
public final class XPCDistributedActorSystem: DistributedActorSystem, Sendable {
  public typealias ActorID = XPCActorID
  public typealias ResultHandler = XPCInvocationResultHandler
  public typealias InvocationEncoder = XPCInvocationEncoder
  public typealias InvocationDecoder = XPCInvocationDecoder
  public typealias SerializationRequirement = XPCMarshal

  private let activeActorsLock: Mutex<[ActorID: any DistributedActor]> = Mutex([:])

  private let ids = Atomic<UInt64>(0)
  private let assignedIDsLock: Mutex<Set<ActorID>> = Mutex([])

  private let reservedIDLock: Mutex<ActorID?> = Mutex(nil)

  private let defaultActorFactoryLock: Mutex<(@Sendable (ActorID) -> any DistributedActor)?> =
    Mutex(nil)
  public let connection: XPCConnection

  public init(connection: XPCConnection) {
    self.connection = connection
    self.connection.addInvalidationHandler { [weak self] in
      self?.activeActorsLock.withLock { $0.removeAll() }
    }
    installEventHandler()
  }

  public func resolve<Act>(id: ActorID, as actorType: Act.Type)
    throws -> Act? where Act: DistributedActor
  {
    activeActorsLock.withLock { $0[id] as? Act }
  }

  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
  where Act: DistributedActor {
    if let reserved = reservedIDLock.withLock({
      let r = $0
      $0 = nil
      return r
    }) {
      var current = ids.load(ordering: .relaxed)
      while reserved.id >= current {
        let (success, updated) = ids.compareExchange(
          expected: current, desired: reserved.id + 1, ordering: .relaxed)
        if success { break }
        current = updated
      }
      _ = assignedIDsLock.withLock { $0.insert(reserved) }
      return reserved
    }
    let id = XPCActorID(id: ids.wrappingAdd(1, ordering: .relaxed).newValue)
    _ = assignedIDsLock.withLock { $0.insert(id) }
    return id
  }

  public func registerDefaultActor(
    _ factory: @escaping @Sendable (ActorID, XPCDistributedActorSystem) -> any DistributedActor
  ) {
    defaultActorFactoryLock.withLock {
      $0 = { [weak self] id in
        guard let system = self else { fatalError("System deallocated during actor creation") }
        system.reservedIDLock.withLock { $0 = id }
        return factory(id, system)
      }
    }
  }

  public func registerDefaultActor<Act>(_ type: Act.Type)
  where Act: XPCDefaultActorInitializable {
    registerDefaultActor { _, system in Act(actorSystem: system) }
  }

  public func actorReady<Act>(_ actor: Act)
  where Act: DistributedActor, Act.ID == ActorID {
    guard self.assignedIDsLock.withLock({ $0.contains(actor.id) }) else {
      fatalError("Attempted to mark an unknown actor '\(actor.id)' ready")
    }
    self.activeActorsLock.withLock { $0[actor.id] = actor }
  }

  public func resignID(_ id: ActorID) {
    _ = self.activeActorsLock.withLock { $0.removeValue(forKey: id) }
  }

  public func makeInvocationEncoder() -> InvocationEncoder { .init() }

  func installEventHandler() {
    connection.setEventHandler { [weak self] object in
      guard let self else { return }
      let done = DispatchSemaphore(value: 0)
      Task {
        try? await self.handleIncomingMessage(object)
        done.signal()
      }
      done.wait()
    }
  }

  func dispatchInvocation(_ message: XPCInvocationMessage) async throws -> XPCReplyEnvelope {
    func getOrCreateActor(for id: ActorID) throws -> any DistributedActor {
      if let actor = activeActorsLock.withLock({ $0[id] }) { return actor }
      guard let factory = defaultActorFactoryLock.withLock({ $0 }) else {
        throw XPCDispatchError.unknownActor(id)
      }
      _ = factory(id)
      guard let actor = activeActorsLock.withLock({ $0[id] }) else {
        fatalError("Default actor factory failed to register actor for \(id)")
      }
      return actor
    }
    let actor = try getOrCreateActor(for: message.actorID)

    guard let metadataProvider = type(of: actor) as? any XPCDistributedTargetMetadataProviding.Type
    else {
      throw XPCDispatchError.missingTargetMetadata(String(describing: type(of: actor)))
    }
    guard metadataProvider.xpcDistributedTargetMetadata[message.method] != nil else {
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
    return metadataProvider.xpcDistributedTargetMetadata[method]?.thrownErrorType
  }

  func handleIncomingMessage(_ object: XPCObject) async throws {
    let received = try XPCDictionary.unmarshal(from: object)
    let resultHandler = XPCInvocationResultHandler(received: received)
    do {
      let invocation = try XPCInvocationMessage.unmarshal(from: object)
      let envelope = try await dispatchInvocation(invocation)
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

@XPCMarshal
@available(macOS 13.0, *)
public struct XPCActorID: Hashable, Sendable, Codable, Equatable {
  internal let id: UInt64
  public init(id: UInt64) { self.id = id }
}

@available(macOS 15, *)
public struct XPCInvocationResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = XPCMarshal
  private let sendEnvelope: @Sendable (XPCReplyEnvelope) throws -> Void

  init(_ sendEnvelope: @escaping @Sendable (XPCReplyEnvelope) throws -> Void) {
    self.sendEnvelope = sendEnvelope
  }

  init(received: SwiftXPC.XPCDictionary) {
    self.sendEnvelope = { envelope in
      guard var reply = XPCDictionary(replyTo: received), let connection = received.connection
      else { return }
      try envelope.write(to: &reply)
      connection.sendAndForget(message: reply)
    }
  }

  func send(_ envelope: XPCReplyEnvelope) throws { try sendEnvelope(envelope) }

  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
    try send(XPCReplyEnvelope(kind: .returnValue, payload: try value.marshal()))
  }

  public func onReturnVoid() async throws { try send(XPCReplyEnvelope(kind: .returnVoid)) }

  public func onThrow<Err: Error>(error: Err) async throws {
    guard let error = error as? any ErrorXPCMarshal else {
      throw XPCRemoteCallError.unsupportedThrownErrorType(String(describing: Err.self))
    }
    try send(XPCReplyEnvelope(kind: .throwError, payload: try error.marshal()))
  }
}

typealias ErrorXPCMarshal = XPCMarshal & Error

@available(macOS 15, *)
@XPCMarshal
enum XPCRemoteCallError: Error, Sendable, Equatable {
  case invalidReplyKind(expected: XPCReplyKind, actual: XPCReplyKind)
  case missingPayload(XPCReplyKind)
  case unsupportedThrownErrorType(String)
}

@available(macOS 13.0, *)
extension RemoteCallTarget: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try identifier.marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> RemoteCallTarget {
    .init(try .unmarshal(from: object))
  }
}

@available(macOS 15, *)
public protocol XPCDefaultActorInitializable: DistributedActor
where ActorSystem == XPCDistributedActorSystem, ID == XPCActorID {
  init(actorSystem: XPCDistributedActorSystem)
}
