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

@Test func DirectLocalActorReferenceRoundTrip() async throws {
  guard #available(macOS 15, *) else { return }
  let system = XPCDistributedActorSystem(connection: makeIdleConnection())
  let worker = ChannelWorker(actorSystem: system)

  let object = try worker.marshal()
  let proxy = try ChannelWorker.unmarshal(from: object)

  #expect(try await proxy.greet("Direct") == "Hello, Direct!")
}

@Test func RootBootstrapReturnsRemoteRoot() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ChannelRoot.self)
  defer { channel.close() }
  let root = try ChannelRoot.connect(using: channel.client)

  #expect(try await root.ping() == "root")
}

@Test func RootReturnsActorOnIndependentChannel() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ChannelRoot.self)
  defer { channel.close() }
  let root = try ChannelRoot.connect(using: channel.client)
  let worker = try await root.makeWorker()

  #expect(try await worker.greet("World") == "Hello, World!")
}

@Test func ActorParameterProvidesReverseCallbackChannel() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ChannelRoot.self)
  defer { channel.close() }
  let root = try ChannelRoot.connect(using: channel.client)
  let worker = try await root.makeWorker()
  let messages = MessageStore()
  let callbackSystem = XPCDistributedActorSystem(connection: makeIdleConnection())
  let callback = ChannelCallback(messages: messages, actorSystem: callbackSystem)

  try await worker.notify(callback)

  #expect(messages.values == ["called back"])
}

@Test func RootProxyExportIsRejected() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ChannelRoot.self)
  defer { channel.close() }
  let root = try ChannelRoot.connect(using: channel.client)

  do {
    // The root channel belongs to this client; it has no stored wire to
    // re-emit and must not be shared with a third process.
    _ = try root.marshal()
    Issue.record("Expected root proxy export to fail")
  } catch let error {
    #expect(error.kind == .remoteActorExportUnsupported("ChannelRoot"))
  }
}

@Test func InvalidatingChildChannelDoesNotInvalidateRoot() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ChannelRoot.self)
  defer { channel.close() }
  let root = try ChannelRoot.connect(using: channel.client)
  let worker = try await root.makeWorker()

  worker.actorSystem.connection.cancel()

  await #expect(throws: XPCConnection.ConnectionError.invalid) {
    _ = try await worker.greet("closed")
  }
  #expect(try await root.ping() == "root")
  let replacement = try await root.makeWorker()
  #expect(try await replacement.greet("again") == "Hello, again!")
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
      error.kind
        == .unsupportedProtocolVersion(
          expected: XPCWireProtocol.currentVersion,
          actual: XPCWireProtocol.currentVersion + 1))
  }
}

// MARK: - Export session peer lifecycle

@available(macOS 15, *)
private enum ExportPairError: Error {
  case peerAcceptTimedOut
}

/// A test-owned root channel so the server-side system — and with it the
/// export session registry — is directly observable.
@available(macOS 15, *)
private struct ExportPair {
  let listener: XPCConnection
  let client: XPCConnection
  let clientSystem: XPCDistributedActorSystem
  let serverSystem: XPCDistributedActorSystem

  func close() {
    client.cancel()
    serverSystem.connection.cancel()
    listener.cancel()
  }
}

@available(macOS 15, *)
private func makeExportPair() throws -> ExportPair {
  let listener = XPCConnection(name: nil)
  let captured = Mutex<(XPCDistributedActorSystem, ChannelRoot)?>(nil)
  let accepted = DispatchSemaphore(value: 0)

  listener.setEventHandler { object in
    guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
    let server = XPCConnection(xpc_object: object.xpc_object)
    let serverSystem = XPCDistributedActorSystem(connection: server)
    serverSystem.reserveRootID()
    let root = ChannelRoot(actorSystem: serverSystem)
    serverSystem.bind(server, to: root)
    captured.withLock { $0 = (serverSystem, root) }
    server.activate()
    accepted.signal()
  }
  listener.activate()

  let client = try XPCConnection.unmarshal(from: listener.marshal())
  let clientSystem = XPCDistributedActorSystem(connection: client)
  client.activate()
  client.sendAndForget(message: XPCDictionary())

  guard accepted.wait(timeout: .now() + 5) == .success,
    let (serverSystem, _) = captured.withLock({ $0 })
  else {
    throw ExportPairError.peerAcceptTimedOut
  }
  return ExportPair(
    listener: listener,
    client: client,
    clientSystem: clientSystem,
    serverSystem: serverSystem
  )
}

@available(macOS 15, *)
private func totalExportPeerCount(of system: XPCDistributedActorSystem) -> Int {
  system.exportSessionsLock.withLock { sessions in
    sessions.values.reduce(0) { $0 + $1.peerCount }
  }
}

@Test func DroppingImportedProxyDrainsExportSessionPeers() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeExportPair()
  defer { pair.close() }
  let root = try ChannelRoot.resolve(id: .root, using: pair.clientSystem)
  // An explicitly nilled var releases the proxy (and its owned system)
  // deterministically even in debug builds.
  var worker: ChannelWorker? = try await root.makeWorker()
  _ = try await worker?.greet("warmup")

  var deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline, totalExportPeerCount(of: pair.serverSystem) < 1 {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(totalExportPeerCount(of: pair.serverSystem) == 1)

  worker = nil

  deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline, totalExportPeerCount(of: pair.serverSystem) != 0 {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(totalExportPeerCount(of: pair.serverSystem) == 0)
  // The listener is session-scoped by design: it outlives the drained peers.
  #expect(pair.serverSystem.exportSessionsLock.withLock { !$0.isEmpty })
}

@Test func PeerDeathDrainsExportSessionPeers() async throws {
  guard #available(macOS 15, *) else { return }
  let pair = try makeExportPair()
  defer { pair.close() }
  let root = try ChannelRoot.resolve(id: .root, using: pair.clientSystem)
  let worker = try await root.makeWorker()
  _ = try await worker.greet("warmup")

  var deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline, totalExportPeerCount(of: pair.serverSystem) < 1 {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(totalExportPeerCount(of: pair.serverSystem) == 1)

  worker.actorSystem.connection.cancel()

  deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline, totalExportPeerCount(of: pair.serverSystem) != 0 {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(totalExportPeerCount(of: pair.serverSystem) == 0)
  #expect(pair.serverSystem.exportSessionsLock.withLock { !$0.isEmpty })
}

@Test func DroppingPeerBoxCancelsItsConnection() async throws {
  guard #available(macOS 15, *) else { return }
  let invalidated = Mutex(false)
  let connection = XPCConnection(name: nil)
  connection.addInvalidationHandler { invalidated.withLock { $0 = true } }
  connection.setEventHandler { _ in }
  connection.activate()

  var box: PeerBox? = PeerBox(connection)
  box = nil

  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline, !invalidated.withLock({ $0 }) {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(invalidated.withLock { $0 })
}
