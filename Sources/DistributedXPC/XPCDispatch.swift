// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

@available(macOS 15, *)
@XPCMarshal
public enum XPCDispatchError: Error, Sendable, Equatable {
  case unknownActor(XPCActorID)
  case unknownTarget(String)
  case nonDispatchingActorType(String)
}

@available(macOS 15, *)
struct XPCDispatchArguments: @unchecked Sendable {
  let array: XPCArray
}

@available(macOS 15, *)
struct AnyXPCDistributedTargetHandler: Sendable {
  private let _invoke: @Sendable (any DistributedActor, XPCDispatchArguments) async throws -> XPCReplyEnvelope

  public init<Act>(
    _ invoke: @escaping @Sendable (Act, XPCDispatchArguments) async throws -> XPCReplyEnvelope
  )
  where Act: DistributedActor, Act.ActorSystem == XPCDistributedActorSystem, Act.ID == XPCActorID {
    self._invoke = { actor, arguments in
      guard let actor = actor as? Act else {
        throw XPCDispatchError.nonDispatchingActorType(String(describing: type(of: actor)))
      }
      return try await invoke(actor, arguments)
    }
  }

  func invoke(on actor: any DistributedActor, arguments: XPCDispatchArguments) async throws -> XPCReplyEnvelope {
    try await _invoke(actor, arguments)
  }
}

@available(macOS 15, *)
protocol XPCDistributedTargetDispatching: DistributedActor
where ActorSystem == XPCDistributedActorSystem, ID == XPCActorID {
  static var xpcDistributedTargetHandlers: [String: AnyXPCDistributedTargetHandler] { get }
  static func _xpcDispatchAny(
    _ actor: any DistributedActor,
    target: RemoteCallTarget,
    arguments: XPCDispatchArguments
  ) async throws -> XPCReplyEnvelope
}

@available(macOS 15, *)
extension XPCDistributedTargetDispatching {
  static func _xpcDispatchAny(
    _ actor: any DistributedActor,
    target: RemoteCallTarget,
    arguments: XPCDispatchArguments
  ) async throws -> XPCReplyEnvelope {
    guard let handler = Self.xpcDistributedTargetHandlers[target.identifier] else {
      throw XPCDispatchError.unknownTarget(target.identifier)
    }
    return try await handler.invoke(on: actor, arguments: arguments)
  }
}
