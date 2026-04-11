// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import SwiftXPC
import Testing

@available(macOS 15, *)
distributed actor SampleDispatchActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func greet(name: String) -> String {
    "Hello, \(name)!"
  }

  distributed func ping() {}
}

@available(macOS 15, *)
distributed actor SampleActorWithoutMetadata {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() {}
}

@available(macOS 15, *)
private let sampleGreetTargetIdentifier = "$s13SwiftXPCTests19SampleDispatchActorC5greet4nameS2S_tYaKFTE"

@available(macOS 15, *)
private let samplePingTargetIdentifier = "$s13SwiftXPCTests19SampleDispatchActorC4pingyyYaKFTE"

@available(macOS 15, *)
private let sampleActorWithoutMetadataPingTargetIdentifier =
  "$s13SwiftXPCTests26SampleActorWithoutMetadataC4pingyyYaKFTE"

@available(macOS 15, *)
extension SampleDispatchActor: XPCDistributedTargetMetadataProviding {
  static var xpcDistributedTargetMetadata: [String: XPCDistributedTargetMetadata] {
    [
      sampleGreetTargetIdentifier: .init(
        argumentCount: 1,
        returnKind: .value,
        returnType: String.self
      ),
      samplePingTargetIdentifier: .init(
        argumentCount: 0,
        returnKind: .void
      ),
    ]
  }
}

@available(macOS 15, *)
private func makeSystem() -> XPCDistributedActorSystem {
  XPCDistributedActorSystem(connection: XPCConnection(name: nil))
}

@Test func DispatchInvocationExecutesDistributedTarget() async throws {
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
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: arguments
    )
  )

  #expect(reply.kind == .returnValue)
  #expect(try String.unmarshal(from: reply.payload!) == "Hello, world!")
}

@Test func DispatchInvocationExecutesVoidDistributedTarget() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      actorID: XPCActorID(id: 1),
      target: RemoteCallTarget(samplePingTargetIdentifier),
      arguments: XPCArray()
    )
  )

  #expect(reply.kind == .returnVoid)
  #expect(reply.payload == nil)
}

@Test func DispatchInvocationFailsForUnknownTarget() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        actorID: XPCActorID(id: 1),
        target: RemoteCallTarget("missing"),
        arguments: XPCArray()
      )
    )
    Issue.record("Expected missing target to throw")
  } catch let error as XPCDispatchError {
    #expect(error == .unknownTarget("missing"))
  } catch {
    Issue.record("Expected XPCDispatchError, got \(error)")
  }
}

@Test func DispatchInvocationValidatesMetadataArgumentCount() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        actorID: XPCActorID(id: 1),
        target: RemoteCallTarget(sampleGreetTargetIdentifier),
        arguments: XPCArray()
      )
    )
    Issue.record("Expected argument count mismatch to throw")
  } catch let error as XPCDispatchError {
    #expect(error == .argumentCountMismatch(expected: 1, actual: 0))
  } catch {
    Issue.record("Expected XPCDispatchError, got \(error)")
  }
}

@Test func DispatchInvocationRequiresTargetMetadata() async throws {
  guard #available(macOS 15, *) else {
    return
  }
  let system = makeSystem()
  _ = SampleActorWithoutMetadata(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        actorID: XPCActorID(id: 1),
        target: RemoteCallTarget(sampleActorWithoutMetadataPingTargetIdentifier),
        arguments: XPCArray()
      )
    )
    Issue.record("Expected missing target metadata to throw")
  } catch let error as XPCDispatchError {
    #expect(error == .missingTargetMetadata("SampleActorWithoutMetadata"))
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
    target: RemoteCallTarget(sampleGreetTargetIdentifier),
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
