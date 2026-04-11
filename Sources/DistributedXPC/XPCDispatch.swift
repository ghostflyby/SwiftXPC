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
  case argumentCountMismatch(expected: Int, actual: Int)
}

@available(macOS 15, *)
struct XPCDispatchArguments: @unchecked Sendable {
  let array: XPCArray
}

@available(macOS 15, *)
struct AnyXPCDistributedTargetHandler: Sendable {
  private let _invoke: @Sendable (any DistributedActor, XPCDispatchArguments) async throws -> XPCReplyEnvelope

  init<Act>(
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

  init<Act, Success>(
    _ invoke: @escaping @Sendable (Act) async throws -> Success
  )
  where
    Act: DistributedActor,
    Act.ActorSystem == XPCDistributedActorSystem,
    Act.ID == XPCActorID,
    Success: XPCMarshal & Sendable
  {
    self.init { actor, arguments in
      try arguments.validateCount(0)
      let value = try await invoke(actor)
      return XPCReplyEnvelope(kind: .returnValue, payload: try value.marshal())
    }
  }

  init<Act>(
    _ invoke: @escaping @Sendable (Act) async throws -> Void
  )
  where Act: DistributedActor, Act.ActorSystem == XPCDistributedActorSystem, Act.ID == XPCActorID {
    self.init { actor, arguments in
      try arguments.validateCount(0)
      try await invoke(actor)
      return XPCReplyEnvelope(kind: .returnVoid)
    }
  }

  init<Act, Argument, Success>(
    _ invoke: @escaping @Sendable (Act, Argument) async throws -> Success
  )
  where
    Act: DistributedActor,
    Act.ActorSystem == XPCDistributedActorSystem,
    Act.ID == XPCActorID,
    Argument: XPCMarshal & Sendable,
    Success: XPCMarshal & Sendable
  {
    self.init { actor, arguments in
      try arguments.validateCount(1)
      var decoder = XPCInvocationDecoder(array: arguments.array)
      let argument: Argument = try decoder.decodeNextArgument()
      let value = try await invoke(actor, argument)
      return XPCReplyEnvelope(kind: .returnValue, payload: try value.marshal())
    }
  }

  init<Act, Argument>(
    _ invoke: @escaping @Sendable (Act, Argument) async throws -> Void
  )
  where
    Act: DistributedActor,
    Act.ActorSystem == XPCDistributedActorSystem,
    Act.ID == XPCActorID,
    Argument: XPCMarshal & Sendable
  {
    self.init { actor, arguments in
      try arguments.validateCount(1)
      var decoder = XPCInvocationDecoder(array: arguments.array)
      let argument: Argument = try decoder.decodeNextArgument()
      try await invoke(actor, argument)
      return XPCReplyEnvelope(kind: .returnVoid)
    }
  }

  func invoke(on actor: any DistributedActor, arguments: XPCDispatchArguments) async throws -> XPCReplyEnvelope {
    try await _invoke(actor, arguments)
  }
}

@available(macOS 15, *)
extension XPCDispatchArguments {
  func validateCount(_ expected: Int) throws {
    guard array.count == expected else {
      throw XPCDispatchError.argumentCountMismatch(expected: expected, actual: array.count)
    }
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
