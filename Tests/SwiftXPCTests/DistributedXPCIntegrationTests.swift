// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Distributed
import DistributedXPC
import SwiftXPCMacros
import Synchronization
import Testing
import XPC

@testable import SwiftXPC

@available(macOS 15, *)
enum IntegrationError: Error, Equatable, XPCMarshal {
  case rejected

  public func marshal() throws(XPCMarshalError) -> XPCObject {
    try "rejected".marshal()
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> IntegrationError {
    switch try String.unmarshal(from: object) {
    case "rejected": return .rejected
    case let value: throw XPCMarshalError.unknownEnumCase(value, enumName: "IntegrationError")
    }
  }
}

@available(macOS 15, *)
@XPCMarshal
struct IntegrationNote: Equatable {
  var title: String
  var tags: [String]
  var replies: [Greeting?]
  var metadata: [String: Greeting]
}

@available(macOS 15, *)
@XPCService
distributed actor IntegrationGreeter {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func greet(name: String) throws(IntegrationError) -> String {
    guard name != "error" else { throw IntegrationError.rejected }
    return "Hello, \(name)!"
  }

  distributed func compose(
    note: IntegrationNote, greeting: String, times: Int
  ) throws(IntegrationError) -> IntegrationNote {
    guard times > 0 else { throw IntegrationError.rejected }
    return IntegrationNote(
      title: "\(greeting) x\(times)",
      tags: note.tags + [greeting],
      replies: note.replies,
      metadata: note.metadata
    )
  }

  distributed func ping() {}
}

@available(macOS 15, *)
extension IntegrationGreeter: XPCDefaultActorInitializable {}

// MARK: - Raw wire helpers

@available(macOS 15, *)
private let integrationGreetTargetIdentifier =
  "$s13SwiftXPCTests18IntegrationGreeterC5greet4nameS2S_tYaKFTE"

@available(macOS 15, *)
private func sendRawInvocation(
  _ message: XPCInvocationMessage, over pair: IntegrationConnectionPair
) async throws -> XPCReplyEnvelope {
  let wire = try XPCDictionary.unmarshal(from: message.marshal())
  let reply = try await pair.client.send(message: wire)
  return try XPCReplyEnvelope.unmarshal(from: reply)
}

// MARK: - TN3113: xpc_connection_create(NULL) + endpoint (exactly 2 connections)

@available(macOS 15, *)
private enum IntegrationConnectionError: Error {
  case peerAcceptTimedOut
}

@available(macOS 15, *)
private struct AcceptedPeer: Sendable {
  let connection: XPCConnection
  let system: XPCDistributedActorSystem
}

@available(macOS 15, *)
private struct IntegrationConnectionPair: Sendable {
  let listener: XPCConnection
  let server: XPCConnection
  let client: XPCConnection
  let serverSystem: XPCDistributedActorSystem
  let clientSystem: XPCDistributedActorSystem
}

@available(macOS 15, *)
private func makeConnectionPair() throws -> IntegrationConnectionPair {
  let listener = XPCConnection(name: nil)
  let acceptedPeer = Mutex<AcceptedPeer?>(nil)
  let accepted = DispatchSemaphore(value: 0)

  listener.setEventHandler { object in
    guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
    let server = XPCConnection(xpc_object: object.xpc_object)
    let serverSystem = XPCDistributedActorSystem(connection: server)
    acceptedPeer.withLock { $0 = AcceptedPeer(connection: server, system: serverSystem) }
    server.activate()
    accepted.signal()
  }
  listener.activate()

  let endpoint = try listener.marshal()
  let client = try XPCConnection.unmarshal(from: endpoint)
  let clientSystem = XPCDistributedActorSystem(connection: client)
  client.activate()
  client.sendAndForget(message: XPCDictionary())

  guard accepted.wait(timeout: .now() + 5) == .success,
    let peer = acceptedPeer.withLock({ $0 })
  else {
    throw IntegrationConnectionError.peerAcceptTimedOut
  }

  return IntegrationConnectionPair(
    listener: listener,
    server: peer.connection,
    client: client,
    serverSystem: peer.system,
    clientSystem: clientSystem
  )
}

// MARK: - Tests

@Test func InProcessRoundTripGreet() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  pair.serverSystem.registerDefaultActor(IntegrationGreeter.self)
  let greeter = IntegrationGreeter(actorSystem: pair.clientSystem)
  let result = try await greeter.greet(name: "World")
  #expect(result == "Hello, World!")
}

@Test func RemoteCallRoundTripGreet() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)
  let stub = try IntegrationGreeter.resolve(id: serverActor.id, using: pair.clientSystem)
  let result = try await stub.greet(name: "Remote")
  #expect(result == "Hello, Remote!")
}

@Test func RemoteCallRoundTripError() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)
  let stub = try IntegrationGreeter.resolve(id: serverActor.id, using: pair.clientSystem)
  await #expect(throws: IntegrationError.rejected) {
    _ = try await stub.greet(name: "error")
  }
}

@Test func RemoteCallRoundTripVoid() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)
  let stub = try IntegrationGreeter.resolve(id: serverActor.id, using: pair.clientSystem)
  try await stub.ping()
}

@Test func RemoteCallRoundTripMultiArgumentNestedPayload() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)
  let stub = try IntegrationGreeter.resolve(id: serverActor.id, using: pair.clientSystem)

  let note = IntegrationNote(
    title: "notes",
    tags: ["a", "b"],
    replies: [Greeting(id: 1, message: "hi", note: nil), nil],
    metadata: ["key": Greeting(id: 2, message: "yo", note: "meta")]
  )

  let result = try await stub.compose(note: note, greeting: "hey", times: 3)

  #expect(result.title == "hey x3")
  #expect(result.tags == ["a", "b", "hey"])
  #expect(result.replies == note.replies)
  #expect(result.metadata == note.metadata)
}

@Test func RemoteCallRoundTripConcurrentCalls() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)
  let stub = try IntegrationGreeter.resolve(id: serverActor.id, using: pair.clientSystem)

  var expected: Set<String> = []
  try await withThrowingTaskGroup(of: String.self) { group in
    for index in 0..<20 {
      expected.insert("Hello, call-\(index)!")
      group.addTask { try await stub.greet(name: "call-\(index)") }
    }
    var results: Set<String> = []
    for try await result in group {
      results.insert(result)
    }
    #expect(results == expected)
  }
}

@Test func RemoteCallSurfacesUnknownActorError() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  _ = IntegrationGreeter(actorSystem: pair.serverSystem)

  let reply = try await sendRawInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: XPCActorID(id: 999),
      target: RemoteCallTarget("unknown"),
      arguments: SwiftXPC.XPCArray()
    ), over: pair)

  #expect(reply.kind == .throwError)
  let error = try XPCDispatchError.unmarshal(from: reply.payload!)
  #expect(error == .unknownActor(XPCActorID(id: 999)))
}

@Test func RemoteCallSurfacesUnknownTargetError() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)

  let reply = try await sendRawInvocation(
    XPCInvocationMessage(
      method: "missing",
      actorID: serverActor.id,
      target: RemoteCallTarget("missing"),
      arguments: SwiftXPC.XPCArray()
    ), over: pair)

  #expect(reply.kind == .throwError)
  let error = try XPCDispatchError.unmarshal(from: reply.payload!)
  #expect(error == .unknownTarget("missing"))
}

@Test func RemoteCallSurfacesArgumentDecodeError() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)

  var arguments = SwiftXPC.XPCArray()
  arguments.append(try Int(42).marshal())

  let reply = try await sendRawInvocation(
    XPCInvocationMessage(
      method: "greet(name:)",
      actorID: serverActor.id,
      target: RemoteCallTarget(integrationGreetTargetIdentifier),
      arguments: arguments
    ), over: pair)

  #expect(reply.kind == .throwError)
  let error = try XPCMarshalError.unmarshal(from: reply.payload!)
  #expect(error.kind == .typeMismatch(expected: "string", actual: "int64"))
}

@Test func SendAfterInvalidationThrowsConnectionError() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  pair.client.cancel()

  do {
    _ = try await pair.client.send(message: XPCDictionary())
    Issue.record("Expected send on invalidated connection to throw")
  } catch XPCConnection.ConnectionError.invalid {
    // expected
  } catch {
    Issue.record("Expected .invalid, got \(error)")
  }
}

@Test func ConnectionInvalidationClearsActorRegistry() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeConnectionPair()
  let serverActor = IntegrationGreeter(actorSystem: pair.serverSystem)
  #expect(try pair.serverSystem.resolve(id: serverActor.id, as: IntegrationGreeter.self) != nil)

  pair.client.cancel()

  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline {
    if try pair.serverSystem.resolve(id: serverActor.id, as: IntegrationGreeter.self) == nil {
      return
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("Server actor registry was not cleared after connection invalidation")
}
