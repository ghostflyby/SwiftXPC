// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import SwiftXPC
import Testing

@available(macOS 15, *)
distributed actor SampleDispatchActor: XPCDistributedTargetDispatching {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func greet(name: String) -> String {
    "Hello, \(name)!"
  }

  distributed func ping() {}
}

@available(macOS 15, *)
extension SampleDispatchActor {
  static var xpcDistributedTargetHandlers: [String: AnyXPCDistributedTargetHandler] {
    [
      "greet": .init { (actor: SampleDispatchActor, name: String) in
        try await actor.greet(name: name)
      },
      "ping": .init { (actor: SampleDispatchActor) in
        try await actor.ping()
      },
    ]
  }
}

@available(macOS 15, *)
private func makeSystem() -> XPCDistributedActorSystem {
  XPCDistributedActorSystem(connection: XPCConnection(name: nil))
}

@Test func DispatchInvocationRoutesToActorHandler() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  var arguments = XPCArray()
  arguments.append(try "world".marshal())

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      actorID: XPCActorID(id: 1),
      target: RemoteCallTarget("greet"),
      arguments: arguments
    )
  )

  #expect(reply.kind == .returnValue)
  #expect(try String.unmarshal(from: reply.payload!) == "Hello, world!")
}

@Test func DispatchInvocationFailsForUnknownTarget() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  await #expect(throws: XPCDispatchError.unknownTarget("missing")) {
    try await system.dispatchInvocation(
      XPCInvocationMessage(
        actorID: XPCActorID(id: 1),
        target: RemoteCallTarget("missing"),
        arguments: XPCArray()
      )
    )
  }
}

@Test func DispatchInvocationFailsForMissingArgument() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        actorID: XPCActorID(id: 1),
        target: RemoteCallTarget("greet"),
        arguments: XPCArray()
      )
    )
    Issue.record("Expected missing argument to throw")
  } catch let error as XPCDispatchError {
    #expect(error == .argumentCountMismatch(expected: 1, actual: 0))
  } catch {
    Issue.record("Expected XPCDispatchError, got \(error)")
  }
}

@Test func HandleIncomingMessageDispatchesInvocation() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  var arguments = XPCArray()
  arguments.append(try "inbox".marshal())

  let message = XPCInvocationMessage(
    actorID: XPCActorID(id: 1),
    target: RemoteCallTarget("greet"),
    arguments: arguments
  )

  try await system.handleIncomingMessage(try message.marshal())
}

@Test func HandleIncomingMessageEncodesDispatchErrors() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  let message = XPCInvocationMessage(
    actorID: XPCActorID(id: 1),
    target: RemoteCallTarget("missing"),
    arguments: XPCArray()
  )

  try await system.handleIncomingMessage(try message.marshal())
}
