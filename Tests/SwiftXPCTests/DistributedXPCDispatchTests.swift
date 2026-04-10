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
      "greet": .init { (actor: SampleDispatchActor, arguments) in
        var decoder = XPCInvocationDecoder(array: arguments.array)
        let name: String = try decoder.decodeNextArgument()
        let result = try await actor.greet(name: name)
        return XPCReplyEnvelope(
          kind: .returnValue,
          payload: try result.marshal()
        )
      },
      "ping": .init { (actor: SampleDispatchActor, arguments) in
        #expect(arguments.array.count == 0)
        try await actor.ping()
        return XPCReplyEnvelope(kind: .returnVoid)
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
