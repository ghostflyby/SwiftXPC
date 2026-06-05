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
@XPCService
distributed actor IntegrationGreeter {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func greet(name: String) throws(IntegrationError) -> String {
    guard name != "error" else { throw IntegrationError.rejected }
    return "Hello, \(name)!"
  }

  distributed func ping() {}
}

@available(macOS 15, *)
extension IntegrationGreeter: XPCDefaultActorInitializable {}

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
