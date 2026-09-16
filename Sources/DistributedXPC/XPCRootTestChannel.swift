// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization

/// An in-process root-actor service bound to an anonymous listener, paired
/// with the client side of the same channel. Built by `xpcTest(_:_:)` to
/// exercise a service without a launchd job:
///
///     let channel = try xpcTest(ServiceRoot.self, XPCServiceConfiguration(
///       onPeerAccept: { connection in /* audit hook fires here too */ }))
///     defer { channel.close() }
///     let root = try channel.root()
///     #expect(try await root.ping() == "pong")
///
/// Nothing here ever exits the process: a cooperative shutdown through
/// `server.requestShutdown()` only tears the sessions down. The channel
/// must be retained (or `close()`d explicitly) for the service to live —
/// releasing it cancels every connection. `server` exposes the hosting
/// `XPCRootActorServer` so tests can drive shutdowns and inspect delegate
/// side effects.
@available(macOS 15, *)
public final class XPCRootTestChannel<Root: XPCRootActor>: @unchecked Sendable {
  /// The server hosting the root on the anonymous listener.
  public let server: XPCRootActorServer<Root>
  /// The client-side connection. Inactive; activate it via `root` or
  /// `Root.connect(using:)`, or manually before sending on it.
  public let client: XPCConnection

  private let listener: XPCConnection
  private let closed = Mutex(false)

  /// Retains the latest server-side peer so tests can simulate the service
  /// dropping the client.
  private final class ServerPeerBox: @unchecked Sendable {
    let peer = Mutex<XPCConnection?>(nil)
  }
  private let serverPeer: ServerPeerBox

  /// Caches the resolved root proxy; `NSLock` because a generic distributed
  /// actor reference carries no static `Sendable` evidence for `Mutex`.
  private final class RootBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Root?
    func get() -> Root? { lock.withLock { value } }
    func setIfEmpty(_ newValue: Root) { lock.withLock { if value == nil { value = newValue } } }
  }
  private let rootBox = RootBox()

  init(
    _ rootType: Root.Type,
    _ delegate: any XPCServiceDelegate<Root>
  ) throws {
    let listener = XPCConnection(name: nil)
    let server = XPCRootActorServer(rootType, delegate)
    let serverPeer = ServerPeerBox()
    listener.setEventHandler { object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      let peer = XPCConnection(xpc_object: object.xpc_object)
      serverPeer.peer.withLock { $0 = peer }
      server.accept(peer)
    }
    listener.activate()

    let client = try XPCConnection.unmarshal(from: listener.marshal())
    self.listener = listener
    self.server = server
    self.client = client
    self.serverPeer = serverPeer
  }

  /// Resolves the root actor over the channel, activating the client
  /// connection. Idempotent: later calls return the same proxy. Throws when
  /// the connection or resolution fails — e.g. after `close()` or a
  /// `dropServerPeer()`.
  public func root() throws -> Root {
    if let cached = rootBox.get() { return cached }
    let root = try Root.connect(using: client)
    rootBox.setIfEmpty(root)
    return root
  }

  /// Dials a fresh, inactive client connection to the same listener, for
  /// tests that exercise multiple sequential or concurrent clients against
  /// one service. Activate it via `Root.connect(using:)` or manually.
  public func makeClient() throws -> XPCConnection {
    try XPCConnection.unmarshal(from: listener.marshal())
  }

  /// Cancels the latest accepted server-side peer, as if the service had
  /// dropped this client; the client then observes its channel going down.
  /// A no-op while no peer has been accepted. Named-service client
  /// connections re-establish on their next call, which is what makes this
  /// useful for exercising restart behavior.
  public func dropServerPeer() {
    serverPeer.peer.withLock { $0 }?.cancel()
  }

  /// Idempotently cancels the client connection, the listener, and every
  /// server session. Also runs from `deinit`.
  public func close() {
    let first = closed.withLock { state -> Bool in
      if state { return false }
      state = true
      return true
    }
    guard first else { return }
    client.cancel()
    listener.cancel()
    server.cancel()
  }

  deinit { close() }
}

/// Spawns an in-process test service serving `rootType` over an anonymous
/// listener and returns the channel pairing it with a client connection.
/// Never exits the process; see `XPCRootTestChannel` for lifetime and
/// inspection details.
///
/// The peer-side delegate semantics are identical to the hosted
/// `xpcMain` entry point — hooks, code signing requirements, and the
/// `XPCServiceExit` singleton hosting all behave the same — minus the
/// process exit.
///
/// - Parameters:
///   - rootType: the concrete root actor type served on the channel.
///   - delegate: the service customization; typically an
///     `XPCServiceConfiguration` whose closures record side effects for
///     assertions.
@available(macOS 15, *)
public func xpcTest<Root: XPCRootActor>(
  _ rootType: Root.Type,
  _ delegate: any XPCServiceDelegate<Root> = XPCServiceConfiguration<Root>()
) throws -> XPCRootTestChannel<Root> {
  try XPCRootTestChannel(rootType, delegate)
}
