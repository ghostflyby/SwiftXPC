// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import SwiftXPC
import Testing
import XPC

/// Exercises overloading: `call(_:)` collides on the metadata key (same base
/// name and labels, different parameter types); `call(value:)` has a distinct
/// key; the `save(_:)` pair collides with *different* typed-throws errors.
@available(macOS 15, *)
@XPCService
distributed actor OverloadActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func call(_ value: Int) -> String {
    "int:\(value)"
  }

  distributed func call(_ value: String) -> String {
    "string:\(value)"
  }

  distributed func call(value: Int) -> String {
    "labeled:\(value)"
  }

  distributed func save(_ id: Int) throws(SaveIntError) {
    // no-op
  }

  distributed func save(_ id: String) throws(SaveStringError) {
    // no-op
  }
}

@available(macOS 15, *)
public struct SaveIntError: Error, XPCMarshal, Equatable {
  public init() {}

  public func marshal() throws(XPCMarshalError) -> XPCObject {
    try "save-int".marshal()
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    switch try String.unmarshal(from: object) {
    case "save-int": return .init()
    case let value: throw .unknownEnumCase(value, enumName: "SaveIntError")
    }
  }
}

@available(macOS 15, *)
public struct SaveStringError: Error, XPCMarshal, Equatable {
  public init() {}

  public func marshal() throws(XPCMarshalError) -> XPCObject {
    try "save-string".marshal()
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    switch try String.unmarshal(from: object) {
    case "save-string": return .init()
    case let value: throw .unknownEnumCase(value, enumName: "SaveStringError")
    }
  }
}

@available(macOS 15, *)
private func makeOverloadSystem() -> XPCDistributedActorSystem {
  XPCDistributedActorSystem(connection: makeIdleConnection())
}

// MARK: - Reproduction: collisions in the generated metadata table

@Test func OverloadMetadataCollapsesSameLabelKey() async throws {
  guard #available(macOS 15, *) else { return }
  let table = OverloadActor.xpcDistributedTargetMetadata

  // Both `call(_:)` overloads share one key; the macro deduplicates so the
  // dictionary never sees duplicate entries.
  #expect(table["call()"] != nil)
  #expect(table.keys.filter { $0 == "call()" }.count == 1)
}

@Test func OverloadMetadataOmitsAmbiguousErrorTypes() async throws {
  guard #available(macOS 15, *) else { return }
  let table = OverloadActor.xpcDistributedTargetMetadata

  // The `save(_:)` overloads throw *different* error types, so the shared
  // key's typed-throws record would be ambiguous: the macro degrades it to
  // no metadata. Callers still decode via their own typed error as long as
  // it conforms to XPCMarshal.
  let entry = try #require(table["save()"])
  #expect(entry.thrownErrorType == nil)
}

@Test func OverloadRealClientProxyDispatch() async throws {
  guard #available(macOS 15, *) else { return }
  let system = makeOverloadSystem()
  let actor = OverloadActor(actorSystem: system)
  let proxy = try OverloadActor.unmarshal(from: try actor.marshal())

  #expect(try await proxy.call(42) == "int:42")
  #expect(try await proxy.call("s") == "string:s")

  // The ambiguous `save(_:)` pair shares a degraded `.init()` entry; the
  // whitelist passes both and each typed error decodes via the caller's own
  // conformance.
  #expect(try await proxy.call(value: 7) == "labeled:7")
  try await proxy.save(1)
  try await proxy.save("s")
}

// MARK: - Distinct keys must not be affected

@Test func DistinctLabelOverloadsGetDistinctKeys() async throws {
  guard #available(macOS 15, *) else { return }
  let table = OverloadActor.xpcDistributedTargetMetadata

  #expect(table["call(value:)"] != nil)
  #expect(table.keys.filter { $0.hasPrefix("call(") }.count == 2)
}
