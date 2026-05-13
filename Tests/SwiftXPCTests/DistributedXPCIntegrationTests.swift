// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import DistributedXPC
import Testing

@testable import SwiftXPC

/// Creates an anonymous same-process XPC connection pair.
///
/// Uses `xpc_endpoint_create` / `xpc_connection_create_from_endpoint`
/// to create two endpoints of a single anonymous connection.
@available(macOS 15, *)
private func makeConnectionPair() throws -> (server: XPCConnection, client: XPCConnection) {
  let server = XPCConnection(name: nil)
  let endpoint = try server.marshal()
  let client = try XPCConnection.unmarshal(from: endpoint)
  return (server, client)
}

// MARK: - Test Actor

@available(macOS 15, *)
@XPCMarshal
enum IntegrationError: Error, Equatable { case rejected }

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

// MARK: - Tests

@Test func InProcessRoundTripGreet() async throws {
  guard #available(macOS 15, *) else { return }
  let (serverConn, clientConn) = try makeConnectionPair()

  let serverSystem = XPCDistributedActorSystem(connection: serverConn)
  serverSystem.registerDefaultActor(IntegrationGreeter.self)

  let clientSystem = XPCDistributedActorSystem(connection: clientConn)
  let greeter = IntegrationGreeter(actorSystem: clientSystem)

  let result = try await greeter.greet(name: "World")
  #expect(result == "Hello, World!")
}

@Test func InProcessRoundTripError() async throws {
  guard #available(macOS 15, *) else { return }
  let (serverConn, clientConn) = try makeConnectionPair()

  let serverSystem = XPCDistributedActorSystem(connection: serverConn)
  serverSystem.registerDefaultActor(IntegrationGreeter.self)

  let clientSystem = XPCDistributedActorSystem(connection: clientConn)
  let greeter = IntegrationGreeter(actorSystem: clientSystem)

  await #expect(throws: IntegrationError.rejected) {
    _ = try await greeter.greet(name: "error")
  }
}

@Test func InProcessRoundTripVoid() async throws {
  guard #available(macOS 15, *) else { return }
  let (serverConn, clientConn) = try makeConnectionPair()

  let serverSystem = XPCDistributedActorSystem(connection: serverConn)
  serverSystem.registerDefaultActor(IntegrationGreeter.self)

  let clientSystem = XPCDistributedActorSystem(connection: clientConn)
  let greeter = IntegrationGreeter(actorSystem: clientSystem)

  try await greeter.ping()
}
