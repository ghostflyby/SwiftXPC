// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation.NSError
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

  public let connection: XPCConnection

  public init(connection: XPCConnection) {
    self.connection = connection
    // Clean up actor registry when the connection is invalidated.
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
    let id = XPCActorID(id: ids.wrappingAdd(1, ordering: .relaxed).newValue)
    _ = assignedIDsLock.withLock {
      $0.insert(id)
    }
    return id
  }

  public func actorReady<Act>(_ actor: Act)
  where Act: DistributedActor, Act.ID == ActorID {
    guard self.assignedIDsLock.withLock({ $0.contains(actor.id) }) else {
      fatalError("Attempted to mark an unknown actor '\(actor.id)' ready")
    }
    self.activeActorsLock.withLock {
      $0[actor.id] = actor
    }
  }

  public func resignID(_ id: ActorID) {
    _ = self.activeActorsLock.withLock {
      $0.removeValue(forKey: id)
    }
  }

  public func makeInvocationEncoder() -> InvocationEncoder {
    .init()
  }

  func installEventHandler() {
    connection.setEventHandler { [weak self] object in
      Task { [weak self] in
        guard let self else {
          return
        }
        try? await self.handleIncomingMessage(object)
      }
    }
  }

  func dispatchInvocation(_ message: XPCInvocationMessage) async throws -> XPCReplyEnvelope {
    let actor = try activeActorsLock.withLock { actors in
      guard let actor = actors[message.actorID] else {
        throw XPCDispatchError.unknownActor(message.actorID)
      }
      return actor
    }

    guard let metadataProvider = type(of: actor) as? any XPCDistributedTargetMetadataProviding.Type else {
      throw XPCDispatchError.missingTargetMetadata(String(describing: type(of: actor)))
    }
    let metadata = try metadataProvider.xpcDistributedTargetMetadata(for: message.target)
    try metadata.validate(arguments: message.arguments)

    var decoder = XPCInvocationDecoder(array: message.arguments)
    let replyLock = Mutex<XPCReplyEnvelope?>(nil)
    let resultHandler = XPCInvocationResultHandler { envelope in
      replyLock.withLock {
        $0 = envelope
      }
    }

    do {
      try await executeDistributedTarget(
        on: actor,
        target: message.target,
        invocationDecoder: &decoder,
        handler: resultHandler
      )
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
    target: RemoteCallTarget,
    throwing errorType: Err.Type
  ) throws -> (any ErrorXPCMarshal.Type)?
  where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    if errorType is any ErrorXPCMarshal.Type {
      return nil
    }

    guard let metadataProvider = actorType as? any XPCDistributedTargetMetadataProviding.Type else {
      return nil
    }
    return try metadataProvider.xpcDistributedTargetMetadata(for: target).thrownErrorType
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
        XPCReplyEnvelope(
          kind: .throwError,
          payload: try error.marshal()
        )
      )
    }
  }

  func decodeRemoteCallReply<Act, Err, Res>(
    _ envelope: XPCReplyEnvelope,
    for actorType: Act.Type,
    target: RemoteCallTarget,
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) throws -> Res
  where
    Act: DistributedActor,
    Act.ID == ActorID,
    Err: Error,
    Res: SerializationRequirement
  {
    let fallbackErrorType = try fallbackThrownErrorType(
      for: actorType,
      target: target,
      throwing: errorType
    )
    return try envelope.decodeReturnValue(
      throwing: errorType,
      returning: returnType,
      fallbackErrorType: fallbackErrorType
    )
  }

  func decodeRemoteCallVoidReply<Act, Err>(
    _ envelope: XPCReplyEnvelope,
    for actorType: Act.Type,
    target: RemoteCallTarget,
    throwing errorType: Err.Type
  ) throws
  where
    Act: DistributedActor,
    Act.ID == ActorID,
    Err: Error
  {
    let fallbackErrorType = try fallbackThrownErrorType(
      for: actorType,
      target: target,
      throwing: errorType
    )
    try envelope.decodeReturnVoid(
      throwing: errorType,
      fallbackErrorType: fallbackErrorType
    )
  }

  public func remoteCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) async throws -> Res
  where
    Act: DistributedActor,
    Act.ID == ActorID,
    Err: Error,
    Res: SerializationRequirement
  {
    let message = XPCInvocationMessage(
      actorID: actor.id,
      target: target,
      arguments: invocation.array
    )
    let payload = try message.marshal()
    let xpcDict = XPCDictionary(xpc_object: payload.xpc_object)
    let result = try await connection.send(message: xpcDict)
    let envelope = try XPCReplyEnvelope.unmarshal(from: result)
    return try decodeRemoteCallReply(
      envelope,
      for: Act.self,
      target: target,
      throwing: errorType,
      returning: returnType
    )
  }

  public func remoteCallVoid<Act, Err>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type
  ) async throws
  where
    Act: DistributedActor,
    Act.ID == ActorID,
    Err: Error
  {
    let message = XPCInvocationMessage(
      actorID: actor.id,
      target: target,
      arguments: invocation.array
    )
    let payload = try message.marshal()
    let xpcDict = XPCDictionary(xpc_object: payload.xpc_object)
    let result = try await connection.send(message: xpcDict)
    let envelope = try XPCReplyEnvelope.unmarshal(from: result)
    try decodeRemoteCallVoidReply(
      envelope,
      for: Act.self,
      target: target,
      throwing: errorType
    )
  }

}

@XPCMarshal
public struct XPCActorID: Hashable, Sendable, Codable, Equatable {
  internal let id: UInt64

  public init(id: UInt64) {
    self.id = id
  }
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
      guard var reply = XPCDictionary(replyTo: received), let connection = received.connection else {
        return
      }

      try envelope.write(to: &reply)
      connection.sendAndForget(message: reply)
    }
  }

  func send(_ envelope: XPCReplyEnvelope) throws {
    try sendEnvelope(envelope)
  }

  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
    try send(
      XPCReplyEnvelope(
        kind: .returnValue,
        payload: try value.marshal()
      )
    )
  }

  public func onReturnVoid() async throws {
    try send(XPCReplyEnvelope(kind: .returnVoid))
  }

  public func onThrow<Err: Error>(error: Err) async throws {
    guard let error = error as? any ErrorXPCMarshal else {
      throw XPCRemoteCallError.unsupportedThrownErrorType(String(describing: Err.self))
    }

    try send(
      XPCReplyEnvelope(
        kind: .throwError,
        payload: try error.marshal()
      )
    )
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
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    try identifier.marshal()
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> RemoteCallTarget {
    .init(try .unmarshal(from: object))
  }
}
