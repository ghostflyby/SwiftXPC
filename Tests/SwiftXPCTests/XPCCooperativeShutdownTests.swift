// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@XPCService
distributed actor ShutdownRoot: TestRoot {
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
  let channel = try await RootChannel(ShutdownRoot.self)
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  channel.host.requestShutdown()
  // Gate on the pipeline itself first: without this, a broken requestShutdown
  // would still let the disconnect wait below resolve via the harness
  // watchdog, and the test would pass without exercising teardown.
  #expect(await channel.host.waitForShutdown(timeout: .seconds(2)))

  // The server-side cancel races with in-flight sends; wait for the client
  // to observe the channel going down (a graceful cancel surfaces as an
  // interruption).
  await channel.client.waitForDisconnection()
  let error = await #expect(throws: XPCChannelError.self) {
    _ = try await root.ping()
  }
  #expect(error == .invalid || error == .interrupted)
}

@Test func ShutdownClosesListenerToNewPeers() async throws {
  let log = XPCServiceEventLog()
  let channel = try await RootChannel(
    ShutdownRoot.self,
    XPCConnectionServiceConfiguration(),
    eventLog: log
  )
  defer { channel.close() }

  channel.host.requestShutdown()

  let lateClient = try channel.makeClient()
  let lateRoot = try ShutdownRoot.connect(using: lateClient)
  let error = await #expect(throws: XPCChannelError.self) {
    _ = try await lateRoot.ping()
  }
  #expect(error == .invalid || error == .interrupted)
  // Native listener closure prevents delivery of another incoming request.
  #expect(log.events.filter { $0.kind == .shouldAcceptPeer }.isEmpty)
}

@Test func ShutdownRejectsBeforeAuditWindow() async throws {
  let log = XPCServiceEventLog()
  let channel = try await RootChannel(
    ShutdownRoot.self,
    XPCConnectionServiceConfiguration(),
    eventLog: log
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")
  #expect(log.events.filter { $0.kind == .shouldAcceptPeer }.count == 1)

  channel.host.requestShutdown()

  let lateClient = try channel.makeClient()
  let lateRoot = try ShutdownRoot.connect(using: lateClient)
  let error = await #expect(throws: XPCChannelError.self) {
    _ = try await lateRoot.ping()
  }
  #expect(error == .invalid || error == .interrupted)
  // Closing the service closes its listener, so no late native audit runs.
  #expect(log.events.filter { $0.kind == .shouldAcceptPeer }.count == 1)
}

@Test func ShutdownFiresOnShutdownExactlyOnce() async throws {
  let log = XPCServiceEventLog()
  let channel = try await RootChannel(
    ShutdownRoot.self,
    XPCConnectionServiceConfiguration(),
    eventLog: log
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  channel.host.requestShutdown()
  channel.host.requestShutdown()
  channel.host.requestShutdown()

  #expect(await log.wait(for: .serviceWillShutdown, timeout: .seconds(2)) != nil)
  #expect(
    log.events.map(\.kind).filter { $0 == .serviceWillShutdown } == [.serviceWillShutdown]
  )
}

@Test func RequestServiceShutdownBridgesFromRootActor() async throws {
  let channel = try await RootChannel(ShutdownRoot.self, XPCConnectionServiceConfiguration())
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)

  // The reply to this very call is normally lost to the synchronous cancel;
  // fire it and observe the teardown instead of awaiting it.
  let reply = Task { try await root.shutdownService() }
  #expect(await channel.host.waitForShutdown(timeout: .seconds(2)))

  await channel.client.waitForDisconnection()
  let error = await #expect(throws: XPCChannelError.self) {
    _ = try await root.ping()
  }
  #expect(error == .invalid || error == .interrupted)
  _ = reply  // resolved by channel.close() cancelling the pending call
}

@Test func RequestServiceShutdownWithoutServerIsNoOp() async throws {
  let system = XPCDistributedActorSystem()
  // Client-side systems host no server session: this must not route anywhere.
  system.requestServiceShutdown()
}
