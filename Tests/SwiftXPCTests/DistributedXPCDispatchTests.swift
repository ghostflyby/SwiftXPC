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
private func makeSystem() -> XPCDistributedActorSystem {
  XPCDistributedActorSystem(connection: makeIdleConnection())
}

@Test func DispatchInvocationExecutesDistributedTarget() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  var arguments = XPCArray()
  arguments.append(try "world".marshal())

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: actor.id,
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: arguments
    ),
    on: actor
  )

  #expect(reply.kind == .returnValue)
  #expect(try String.unmarshal(from: reply.payload!) == "Hello, world!")
}

@Test func DispatchInvocationExecutesVoidDistributedTarget() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "ping()",
      actorID: actor.id,
      target: RemoteCallTarget(samplePingTargetIdentifier),
      arguments: XPCArray()
    ),
    on: actor
  )

  #expect(reply.kind == .returnVoid)
  #expect(reply.payload == nil)
}

@Test func DispatchInvocationFailsForUnknownTarget() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        method: "missing",
        actorID: actor.id,
        target: RemoteCallTarget("missing"),
        arguments: XPCArray()
      ),
      on: actor
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
  let actor = SampleActorWithoutMetadata(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        method: "ping()",
        actorID: actor.id,
        target: RemoteCallTarget(sampleActorWithoutMetadataPingTargetIdentifier),
        arguments: XPCArray()
      ),
      on: actor
    )
    Issue.record("Expected missing target metadata to throw")
  } catch let error as XPCDispatchError {
    #expect(error == .missingTargetMetadata("SampleActorWithoutMetadata"))
  } catch {
    Issue.record("Expected XPCDispatchError, got \(error)")
  }
}

@Test func DispatchInvocationRejectsMismatchedActorID() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        method: "greet(name:)",
        actorID: XPCActorID(id: actor.id.id + 500),
        target: RemoteCallTarget(sampleGreetTargetIdentifier),
        arguments: XPCArray()
      ),
      on: actor
    )
    Issue.record("Expected mismatched actor ID to throw")
  } catch let error as XPCDispatchError {
    #expect(error == .unknownActor(XPCActorID(id: actor.id.id + 500)))
  } catch {
    Issue.record("Expected XPCDispatchError, got \(error)")
  }
}

@Test func HandleIncomingMessageDispatchesInvocation() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  var arguments = XPCArray()
  arguments.append(try "inbox".marshal())

  let message = XPCInvocationMessage(
    method: "greet(name:)",
    actorID: actor.id,
    target: RemoteCallTarget(sampleGreetTargetIdentifier),
    arguments: arguments
  )

  try await system.handleIncomingMessage(try message.marshal(), on: actor)
}

@Test func HandleIncomingMessageEncodesDispatchErrors() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  let message = XPCInvocationMessage(
    method: "missing",
    actorID: actor.id,
    target: RemoteCallTarget("missing"),
    arguments: XPCArray()
  )

  try await system.handleIncomingMessage(try message.marshal(), on: actor)
}

@Test func DispatchInvocationRejectsWrongArgumentType() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  var arguments = XPCArray()
  arguments.append(try Int(42).marshal())

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: actor.id,
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: arguments
    ),
    on: actor
  )

  #expect(reply.kind == .throwError)
  let error = try XPCMarshalError.unmarshal(from: reply.payload!)
  #expect(error.kind == .typeMismatch(expected: "string", actual: "int64"))
}

@Test func DispatchInvocationRejectsMissingArguments() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeSystem()
  let actor = SampleDispatchActor(actorSystem: system)

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: actor.id,
      target: RemoteCallTarget(sampleGreetTargetIdentifier),
      arguments: XPCArray()
    ),
    on: actor
  )

  #expect(reply.kind == .throwError)
  let error = try XPCMarshalError.unmarshal(from: reply.payload!)
  #expect(error.kind == .outOfBounds(index: 0, count: 0))
}

@Test func ParseTargetIdentifierMultiLabelMethodWithClassReturnType() {
  guard #available(macOS 15, *) else { return }
  // The return-type mangling `AA0C4Note` contains a `C` after the class
  // terminator; a rightmost scan would mis-parse this identifier as "Note()".
  let identifier =
    "$s13SwiftXPCTests18IntegrationGreeterC7compose4note8greeting5timesAA0C4NoteVAI_SSSitYaKFTE"
  #expect(parseTargetIdentifier(identifier) == "compose(note:greeting:times:)")
}

@Test func ParseTargetIdentifierStopsAtReturnTypeComponent() {
  guard #available(macOS 15, *) else { return }
  // An unsubstituted struct return type also starts with digits; it must not
  // be swallowed as a parameter label.
  #expect(parseTargetIdentifier("$s4demo8GreeterC5greet4name4NoteYT") == "greet(name:)")
}
