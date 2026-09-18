// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@XPCService
distributed actor ShutdownRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "root"
  }

  /// Simulates a trusted client asking the service to retire itself. The
  /// shutdown cancels the session channel synchronously, so the reply to
  /// this very call is normally lost; clients should treat disconnection as
  /// the completion signal.
  distributed func shutdownService() {
    actorSystem.requestServiceShutdown()
  }
}

@Test func ShutdownTearsDownExistingSession() async throws {
  let channel = try RootChannel(ShutdownRoot.self)
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  channel.host.requestShutdown()

  // The server-side cancel races with in-flight sends; wait for the client
  // to observe the invalidation.
  await channel.client.waitForInvalidation()
  await #expect(throws: XPCConnection.ConnectionError.self) {
    _ = try await root.ping()
  }
}

@Test func ShutdownRejectsNewPeersThroughRejectHook() async throws {
  let log = XPCServiceEventLog()
  let channel = try RootChannel(
    ShutdownRoot.self,
    XPCServiceConfiguration(),
    eventLog: log
  )
  defer { channel.close() }

  channel.host.requestShutdown()

  let lateClient = try channel.makeClient()
  let lateRoot = try ShutdownRoot.connect(using: lateClient)
  await #expect(throws: XPCConnection.ConnectionError.interrupted) {
    _ = try await lateRoot.ping()
  }
  let rejection = await log.expectEvent(.didRejectPeer, timeout: .seconds(2))
  #expect(rejection?.errorDescription == nil)
}

@Test func ShutdownRejectsBeforeAuditWindow() async throws {
  let log = XPCServiceEventLog()
  let channel = try RootChannel(
    ShutdownRoot.self,
    XPCServiceConfiguration(),
    eventLog: log
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")
  #expect(log.events.filter { $0.kind == .shouldAcceptPeer }.count == 1)

  channel.host.requestShutdown()

  let lateClient = try channel.makeClient()
  let lateRoot = try ShutdownRoot.connect(using: lateClient)
  await #expect(throws: XPCConnection.ConnectionError.interrupted) {
    _ = try await lateRoot.ping()
  }
  // The post-shutdown rejection happens before the audit window: the late
  // peer never reached `shouldAccept`.
  #expect(await log.expectEvent(.didRejectPeer, timeout: .seconds(2)) != nil)
  #expect(log.events.filter { $0.kind == .shouldAcceptPeer }.count == 1)
}

@Test func ShutdownFiresOnShutdownExactlyOnce() async throws {
  let log = XPCServiceEventLog()
  let channel = try RootChannel(
    ShutdownRoot.self,
    XPCServiceConfiguration(),
    eventLog: log
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  channel.host.requestShutdown()
  channel.host.requestShutdown()
  channel.host.requestShutdown()

  #expect(await log.expectEvent(.serviceWillShutdown, timeout: .seconds(2)) != nil)
  #expect(
    log.events.map(\.kind).filter { $0 == .serviceWillShutdown } == [.serviceWillShutdown]
  )
}

@Test func RequestServiceShutdownBridgesFromRootActor() async throws {
  let channel = try RootChannel(ShutdownRoot.self, XPCServiceConfiguration())
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)

  // The reply to this very call is normally lost to the synchronous cancel;
  // fire it and observe the teardown instead of awaiting it.
  let reply = Task { try await root.shutdownService() }
  #expect(await channel.host.expectShutdown(timeout: .seconds(2)))

  await channel.client.waitForInvalidation()
  await #expect(throws: XPCConnection.ConnectionError.self) {
    _ = try await root.ping()
  }
  _ = reply  // resolved by channel.close() cancelling the pending call
}

@Test func RequestServiceShutdownWithoutServerIsNoOp() async throws {
  let system = XPCDistributedActorSystem(connection: makeIdleConnection())
  // Client-side systems host no server session: this must not route anywhere.
  system.requestServiceShutdown()
}
