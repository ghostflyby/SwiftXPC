// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Distributed
@testable import DistributedXPC
import SwiftXPC
import SwiftXPCMacros
import Synchronization
import Testing
import XPC

@available(macOS 15, *)
private final class MessageStore: @unchecked Sendable {
  private let messages = Mutex<[String]>([])

  func append(_ message: String) {
    messages.withLock { $0.append(message) }
  }

  var values: [String] {
    messages.withLock { $0 }
  }
}

@available(macOS 15, *)
@XPCService
distributed actor ChannelCallback {
  typealias ActorSystem = XPCDistributedActorSystem

  private let messages: MessageStore

  fileprivate init(messages: MessageStore, actorSystem: ActorSystem) {
    self.messages = messages
    self.actorSystem = actorSystem
  }

  distributed func receive(_ message: String) {
    messages.append(message)
  }
}

@available(macOS 15, *)
@XPCService
distributed actor ChannelWorker {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func greet(_ name: String) -> String {
    "Hello, \(name)!"
  }

  distributed func notify(_ callback: ChannelCallback) async throws {
    try await callback.receive("called back")
  }
}

@available(macOS 15, *)
@XPCService
distributed actor ChannelRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "root"
  }

  distributed func makeWorker() -> ChannelWorker {
    ChannelWorker(actorSystem: actorSystem)
  }
}

@available(macOS 15, *)
private final class RootChannelFixture: @unchecked Sendable {
  let listener: XPCConnection
  let client: XPCConnection
  let server: XPCRootActorServer<ChannelRoot>
  let watchdog: DispatchWorkItem

  init(listener: XPCConnection, client: XPCConnection, server: XPCRootActorServer<ChannelRoot>) {
    self.listener = listener
    self.client = client
    self.server = server
    watchdog = DispatchWorkItem {
      client.cancel()
      listener.cancel()
      server.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
  }

  deinit {
    watchdog.cancel()
    client.cancel()
    listener.cancel()
    server.cancel()
  }
}

@available(macOS 15, *)
private func makeRootChannel() throws -> RootChannelFixture {
  let listener = XPCConnection(name: nil)
  let server = XPCRootActorServer(ChannelRoot.self)

  listener.setEventHandler { object in
    guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
    server.accept(XPCConnection(xpc_object: object.xpc_object))
  }
  listener.activate()

  let client = try XPCConnection.unmarshal(from: listener.marshal())
  return RootChannelFixture(listener: listener, client: client, server: server)
}

@Test func DirectLocalActorReferenceRoundTrip() async throws {
  guard #available(macOS 15, *) else { return }
  let system = XPCDistributedActorSystem(connection: XPCConnection(name: nil))
  let worker = ChannelWorker(actorSystem: system)

  let object = try worker.marshal()
  let proxy = try ChannelWorker.unmarshal(from: object)

  #expect(try await proxy.greet("Direct") == "Hello, Direct!")
}

@Test func RootBootstrapReturnsRemoteRoot() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeRootChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ChannelRoot.connect(using: fixture.client)

  #expect(try await root.ping() == "root")
}

@Test func RootReturnsActorOnIndependentChannel() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeRootChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ChannelRoot.connect(using: fixture.client)
  let worker = try await root.makeWorker()

  #expect(try await worker.greet("World") == "Hello, World!")
}

@Test func ActorParameterProvidesReverseCallbackChannel() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeRootChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ChannelRoot.connect(using: fixture.client)
  let worker = try await root.makeWorker()
  let messages = MessageStore()
  let callbackSystem = XPCDistributedActorSystem(connection: XPCConnection(name: nil))
  let callback = ChannelCallback(messages: messages, actorSystem: callbackSystem)

  try await worker.notify(callback)

  #expect(messages.values == ["called back"])
}

@Test func RemoteProxyExportIsRejected() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeRootChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ChannelRoot.connect(using: fixture.client)
  let worker = try await root.makeWorker()

  do {
    _ = try worker.marshal()
    Issue.record("Expected remote proxy export to fail")
  } catch let error {
    #expect(error.kind == .remoteActorExportUnsupported("ChannelWorker"))
  }
}

@Test func InvalidatingChildChannelDoesNotInvalidateRoot() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeRootChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ChannelRoot.connect(using: fixture.client)
  let worker = try await root.makeWorker()

  worker.actorSystem.connection.cancel()

  await #expect(throws: XPCConnection.ConnectionError.invalid) {
    _ = try await worker.greet("closed")
  }
  #expect(try await root.ping() == "root")
  let replacement = try await root.makeWorker()
  #expect(try await replacement.greet("again") == "Hello, again!")
}

@Test func InvalidatingRootCascadesToChildExports() async throws {
  guard #available(macOS 15, *) else { return }
  let fixture = try makeRootChannel()
  defer { withExtendedLifetime(fixture) {} }
  let root = try ChannelRoot.connect(using: fixture.client)
  let worker = try await root.makeWorker()

  root.actorSystem.connection.cancel()

  await #expect(throws: XPCConnection.ConnectionError.invalid) {
    _ = try await root.ping()
  }
  // The child channel dies via the server-side cascade
  // (root INVALID -> invalidate() -> session.cancel() -> peer.cancel()),
  // which races with in-flight calls; poll instead of asserting once.
  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline {
    do {
      _ = try await worker.greet("closed")
    } catch XPCConnection.ConnectionError.invalid {
      return
    } catch {
      Issue.record("Expected .invalid, got \(error)")
      return
    }
    try? await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("Child export did not fail after root invalidation")
}

@Test func ActorReferenceRejectsUnsupportedVersion() throws {
  guard #available(macOS 15, *) else { return }
  let listener = XPCConnection(name: nil)
  listener.setEventHandler { _ in }
  listener.activate()
  let wire = XPCActorReferenceWire(
    version: XPCWireProtocol.currentVersion + 1,
    actorID: .root,
    endpoint: try listener.marshal()
  )

  do {
    _ = try ChannelWorker.unmarshal(from: wire.marshal())
    Issue.record("Expected unsupported actor-reference version to fail")
  } catch let error {
    #expect(
      error.kind == .unsupportedProtocolVersion(
        expected: XPCWireProtocol.currentVersion,
        actual: XPCWireProtocol.currentVersion + 1))
  }
}
