// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization

/// Peripheral test tool pairing an in-process root-actor service with the
/// client side of the same channel, spawned by `xpcTest(_:_:)`:
///
///     let service = try xpcTest(ServiceRoot.self, XPCServiceConfiguration(
///       onPeerAccept: { connection in /* audit hook fires here too */ }))
///     defer { service.close() }
///     let root = try await service.channel.retrying {
///       try await service.channel.root.ping()
///     }
///
/// The client side is a full production `XPCRootConnection` over the
/// harness's endpoint — `root`, `events`, and `retrying` behave exactly as
/// against a launchd service, with one documented difference: the harness's
/// channel dials the harness's own listener endpoint, so it survives peer
/// drops (transparent re-dial) but dies permanently when the harness closes
/// — only a named-service connection also survives a full service restart.
/// `dropServerPeer()` surfaces as `.disconnected` on `channel.events`.
///
/// The test-only operations live here, not on the channel: `server` exposes
/// the hosting `XPCRootActorServer` (cooperative `requestShutdown()` plus
/// every delegate hook for assertions), `makeClient()` dials additional
/// clients, and `close()` tears everything down. Nothing ever exits the
/// process.
@available(macOS 15, *)
public final class XPCRootTestHarness<Root: XPCRootActor>: @unchecked Sendable {
  /// The client side of the channel: a production `XPCRootConnection`
  /// dialed against the harness's endpoint.
  public let channel: XPCRootConnection<Root>
  /// The server hosting the root on the anonymous listener.
  public let server: XPCRootActorServer<Root>

  private let listener: XPCConnection
  private let closed = Mutex(false)

  /// Retains the latest server-side peer so tests can simulate the service
  /// dropping a client.
  private final class ServerPeerBox: @unchecked Sendable {
    let peer = Mutex<XPCConnection?>(nil)
  }
  private let serverPeer: ServerPeerBox

  init(
    _ rootType: Root.Type,
    _ delegate: any XPCServiceDelegate<Root>
  ) throws {
    let listener = XPCConnection(name: nil)
    let server = XPCRootActorServer<Root>(rootType, delegate)
    let serverPeer = ServerPeerBox()
    listener.setEventHandler { object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      let peer = XPCConnection(xpc_object: object.xpc_object)
      serverPeer.peer.withLock { $0 = peer }
      server.accept(peer)
    }
    listener.activate()

    let endpoint = try XPCConnection.unmarshal(from: listener.marshal())
    let channel = try XPCRootConnection<Root>.connect(using: endpoint)
    self.listener = listener
    self.server = server
    self.channel = channel
    self.serverPeer = serverPeer
  }

  /// Dials a fresh, inactive client connection to the same listener, for
  /// tests that exercise multiple sequential or concurrent clients against
  /// one service. Endpoint-based like every connection here: activate it
  /// via `Root.connect(using:)` or manually; it dies permanently with its
  /// server-side peer.
  public func makeClient() throws -> XPCConnection {
    try XPCConnection.unmarshal(from: listener.marshal())
  }

  /// Cancels the latest accepted server-side peer, as if the service had
  /// dropped that client. The client channel observes `.disconnected` on
  /// `events`; because it dials the harness's *listener* endpoint, libxpc
  /// transparently re-dials while the harness lives and the server accepts
  /// a fresh session — per-session roots are recreated, singleton
  /// (`XPCServiceExit`) roots keep their shared instance. Permanent channel
  /// death requires `close()`. A no-op while no peer has been accepted.
  public func dropServerPeer() {
    serverPeer.peer.withLock { $0 }?.cancel()
  }

  /// Idempotently tears the harness down: the client channel, the listener,
  /// and every server session. Also runs from `deinit`.
  public func close() {
    let first = closed.withLock { state -> Bool in
      if state { return false }
      state = true
      return true
    }
    guard first else { return }
    channel.close()
    listener.cancel()
    server.cancel()
  }

  deinit { close() }
}

/// Spawns an in-process test service serving `rootType` over an anonymous
/// listener and returns the harness pairing it with a production client
/// channel. Never exits the process; see `XPCRootTestHarness` for lifetime
/// and inspection details.
///
/// The delegate semantics are identical to the hosted `xpcMain` entry point
/// — hooks, code signing requirements, and the `XPCServiceExit` singleton
/// hosting all behave the same — minus the process exit.
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
) throws -> XPCRootTestHarness<Root> {
  try XPCRootTestHarness(rootType, delegate)
}
