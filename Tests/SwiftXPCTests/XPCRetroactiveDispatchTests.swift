// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import SwiftXPC
import Testing
import XPC

/// Declared WITHOUT any XPC conformance. Dispatch is permissive for actors
/// without metadata: any distributed target the actor exposes is callable.
distributed actor RetrofittedActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func greet(name: String) -> String {
    "Hello, \(name)!"
  }

  distributed func fail() throws(RetroError) {
    throw RetroError.boom
  }
}

public enum RetroError: Error, XPCMarshal, Equatable {
  case boom

  public func marshal() throws(XPCMarshalError) -> XPCObject {
    try "boom".marshal()
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    switch try String.unmarshal(from: object) {
    case "boom": return .boom
    case let value: throw .unknownEnumCase(value, enumName: "RetroError")
    }
  }
}

@Test func PermissiveDispatchServesNonConformingActor() async throws {
  let system = makeIdleSystem()
  let actor = RetrofittedActor(actorSystem: system)

  var arguments = SwiftXPC.XPCArray()
  arguments.append(try "x".marshal())
  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: actor.id,
      target: RemoteCallTarget(retroGreetTargetIdentifier),
      arguments: arguments
    ),
    on: actor
  )

  #expect(reply.kind == .returnValue)
  #expect(try String.unmarshal(from: reply.payload!) == "Hello, x!")
}

@Test func PermissiveDispatchDecodesMarshalableTypedErrors() async throws {
  let system = makeIdleSystem()
  let actor = RetrofittedActor(actorSystem: system)

  let reply = try await system.dispatchInvocation(
    XPCInvocationMessage(
      method: "fail()",
      actorID: actor.id,
      target: RemoteCallTarget(retroFailTargetIdentifier),
      arguments: SwiftXPC.XPCArray()
    ),
    on: actor
  )

  #expect(reply.kind == .throwError)
  #expect(try RetroError.unmarshal(from: reply.payload!) == .boom)
}

@Test func PermissiveDispatchUnknownTargetFailsAtRuntime() async throws {
  let system = makeIdleSystem()
  let actor = RetrofittedActor(actorSystem: system)

  do {
    _ = try await system.dispatchInvocation(
      XPCInvocationMessage(
        method: "missing()",
        actorID: actor.id,
        target: RemoteCallTarget("missing"),
        arguments: SwiftXPC.XPCArray()
      ),
      on: actor
    )
    Issue.record("Expected unknown target to fail")
  } catch let error as XPCDispatchError {
    guard case .targetExecutionFailed = error else {
      Issue.record("Expected targetExecutionFailed, got \(error)")
      return
    }
  }
}

/// Adding `XPCExportableActor` conformance unlocks actor-reference marshaling
/// (parameters, return values) without any other change.
@Test func ExportableConformanceUnlocksReferenceRoundTrip() async throws {
  let system = makeIdleSystem()
  let actor = RetroExportableActor(actorSystem: system)

  let proxy = try RetroExportableActor.unmarshal(from: try actor.marshal())
  #expect(try await proxy.greet(name: "x") == "Hello, x!")
}

private func makeIdleSystem() -> XPCDistributedActorSystem {
  XPCDistributedActorSystem(connection: makeIdleConnection())
}

/// With reference marshaling opted in.
distributed actor RetroExportableActor: XPCExportableActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func greet(name: String) -> String {
    "Hello, \(name)!"
  }
}

private let retroGreetTargetIdentifier =
  "$s13SwiftXPCTests16RetrofittedActorC5greet4nameS2S_tYaKFTE"

private let retroFailTargetIdentifier =
  "$s13SwiftXPCTests16RetrofittedActorC4failyyYaKFTE"
