// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
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
    fatalError(
      "Attempted to make remote call to \(target) on actor \(actor) using a local-only actor system"
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
    fatalError(
      "Attempted to make remote call to \(target) on actor \(actor) using  a local-only actor system"
    )
  }

}

public struct XPCActorID: Hashable, Sendable, Codable, Equatable {
  let id: UInt64
}

@available(macOS 13.0, *)
public struct XPCInvocationEncoder: DistributedTargetInvocationEncoder {
  public typealias SerializationRequirement = XPCMarshal

  public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
  }

  public mutating func recordArgument<Value: SerializationRequirement>(
    _ argument: RemoteCallArgument<Value>
  ) throws {
    fatalError("Attempted to call encoder method in a local-only actor system")
  }

  public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
  }

  public mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws {
  }

  public mutating func doneRecording() throws {
  }
}

public final class XPCInvocationDecoder: DistributedTargetInvocationDecoder {
  public typealias SerializationRequirement = XPCMarshal

  public func decodeGenericSubstitutions() throws -> [Any.Type] {
    fatalError("Attempted to call decoder method in a local-only actor system")
  }

  public func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument {
    fatalError("Attempted to call decoder method in a local-only actor system")
  }

  public func decodeErrorType() throws -> Any.Type? {
    fatalError("Attempted to call decoder method in a local-only actor system")
  }

  public func decodeReturnType() throws -> Any.Type? {
    fatalError("Attempted to call decoder method in a local-only actor system")
  }
}

public struct XPCInvocationResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = XPCMarshal
  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
    fatalError("Attempted to call decoder method in a local-only actor system")
  }

  public func onReturnVoid() async throws {
    fatalError("Attempted to call decoder method in a local-only actor system")
  }

  public func onThrow<Err: Error>(error: Err) async throws {
    fatalError("Attempted to call decoder method in a local-only actor system")
  }
}
