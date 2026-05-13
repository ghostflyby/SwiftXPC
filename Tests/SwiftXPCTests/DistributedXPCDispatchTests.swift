// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC
import SwiftXPCMacros
import Testing

@testable import DistributedXPC

@available(macOS 15, *)
@XPCService
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
private let sampleGreetTargetIdentifier =
  "$s13SwiftXPCTests19SampleDispatchActorC5greet4nameS2S_tYaKFTE"

@available(macOS 15, *)
private let samplePingTargetIdentifier = "$s13SwiftXPCTests19SampleDispatchActorC4pingyyYaKFTE"

@available(macOS 15, *)
private let sampleActorWithoutMetadataPingTargetIdentifier =
  "$s13SwiftXPCTests26SampleActorWithoutMetadataC4pingyyYaKFTE"

@available(macOS 15, *)
extension SampleDispatchActor: XPCDefaultActorInitializable {}

@available(macOS 15, *)
private func makeSystem() -> XPCDistributedActorSystem {
  XPCDistributedActorSystem(connection: XPCConnection(name: nil))
}

@Test func DispatchInvocationExecutesDistributedTarget() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  var arguments = XPCArray()
  arguments.append(try "world".marshal())

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: XPCActorID(id: 1),
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: arguments
    )
  )

  #expect(reply.kind == .returnValue)
  #expect(try String.unmarshal(from: reply.payload!) == "Hello, world!")
}

@Test func DispatchInvocationExecutesVoidDistributedTarget() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "ping()",
      actorID: XPCActorID(id: 1),
      target: RemoteCallTarget(samplePingTargetIdentifier),
      arguments: XPCArray()
    )
  )

  #expect(reply.kind == .returnVoid)
  #expect(reply.payload == nil)
}

@Test func DispatchInvocationFailsForUnknownTarget() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        method: "missing",
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

@Test func DispatchInvocationRequiresTargetMetadata() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  _ = SampleActorWithoutMetadata(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        method: "ping()",
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
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  var arguments = XPCArray()
  arguments.append(try "inbox".marshal())

  let message = XPCInvocationMessage(
    method: "greet(name:)",
    actorID: XPCActorID(id: 1),
    target: RemoteCallTarget(sampleGreetTargetIdentifier),
    arguments: arguments
  )

  try await system.handleIncomingMessage(try message.marshal())
}

@Test func DispatchInvocationCreatesActorViaRegisteredFactory() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  system.registerDefaultActor(SampleDispatchActor.self)

  var arguments = XPCArray()
  arguments.append(try "factory".marshal())

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: XPCActorID(id: 42),
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: arguments
    )
  )

  #expect(reply.kind == .returnValue)
  #expect(try String.unmarshal(from: reply.payload!) == "Hello, factory!")
}

@Test func DispatchInvocationThrowsUnknownActorWithoutFactory() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        method: "greet(name:)",
        actorID: XPCActorID(id: 99),
        target: RemoteCallTarget(sampleGreetTargetIdentifier),
        arguments: XPCArray()
      )
    )
    Issue.record("Expected unknown actor to throw")
  } catch let error as XPCDispatchError {
    #expect(error == .unknownActor(XPCActorID(id: 99)))
  } catch {
    Issue.record("Expected XPCDispatchError, got \(error)")
  }
}

@Test func DispatchInvocationCreatesActorWithCorrectID() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  system.registerDefaultActor(SampleDispatchActor.self)

  let targetID = XPCActorID(id: 7)
  var arguments = XPCArray()
  arguments.append(try "idcheck".marshal())

  let reply1 = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: targetID,
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: arguments
    )
  )
  #expect(try String.unmarshal(from: reply1.payload!) == "Hello, idcheck!")

  var args2 = XPCArray()
  args2.append(try "again".marshal())
  let reply2 = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: targetID,
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: args2
    )
  )
  #expect(try String.unmarshal(from: reply2.payload!) == "Hello, again!")
}

@Test func HandleIncomingMessageEncodesDispatchErrors() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  _ = SampleDispatchActor(actorSystem: system)

  let message = XPCInvocationMessage(
    method: "missing",
    actorID: XPCActorID(id: 1),
    target: RemoteCallTarget("missing"),
    arguments: XPCArray()
  )

  try await system.handleIncomingMessage(try message.marshal())
}
