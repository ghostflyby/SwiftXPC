// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation.NSError
import SwiftXPC
import Synchronization

/// A `DistributedActorSystem` designed for local only testing.
///
/// It will crash on any attempt of remote communication, but can be useful
/// for learning about `distributed actor` isolation, as well as early
/// prototyping stages of development where a real system is not necessary yet.
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
    let message = XPCSentMessage(
      id: actor.id,
      target: target,
      arguments: invocation.array
    )
    let payload = try message.marshal()
    let xpcDict = XPCDictionary(xpc_object: payload.xpc_object)
    let result = try await connection.send(message: xpcDict)
    return try Res.unmarshal(from: result)
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
    fatalError(
      "Attempted to make remote call to \(target) on actor \(actor) using  a local-only actor system"
    )
  }

}

@XPCMarshal
public struct XPCActorID: Hashable, Sendable, Codable, Equatable {
  internal let id: UInt64
}

public struct XPCInvocationResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = XPCMarshal
  let received: SwiftXPC.XPCDictionary
  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
    let reply = XPCDictionary(replyTo: received)
    guard let reply = reply, let connection = received.connection else {
      return
    }

    connection.sendAndForget(message: reply)
  }

  public func onReturnVoid() async throws {
    let reply = XPCDictionary(replyTo: received)
    guard let reply = reply, let connection = received.connection else {
      return
    }

    connection.sendAndForget(message: reply)
  }

  public func onThrow<Err: Error>(error: Err) async throws {
    let reply = XPCDictionary(replyTo: received)
    guard let reply = reply, let connection = received.connection else {
      return
    }

    connection.sendAndForget(message: reply)
  }
}

typealias ErrorXPCMarshal = XPCMarshal & Error
typealias ErrorCodable = Error & Codable

enum XPCReply: Error {
  case s(XPCObject)
  case xf(ErrorXPCMarshal)
  case cf(ErrorCodable)
  case nf(NSError)
}

@available(macOS 13.0, *)
@XPCMarshal
struct XPCSentMessage {
  let id: XPCActorID
  let target: RemoteCallTarget
  let arguments: SwiftXPC.XPCArray
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
