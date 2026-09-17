// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization

/// The test coordinator for root-actor services: it owns a **simulated
/// service process** — a long-lived actor system private to the
/// coordinator (the `serviceHost` recipe: idle activated channel, child
/// reclamation, `.root` reserved at creation), a **fresh** root instance
/// constructed on it (never the process-global `XPCRootActor.shared`), and
/// an anonymous listener — and coordinates the test's connection model:
/// handing out the production client channel, dialing additional clients,
/// and simulating service-side drops.
///
///     let service = try xpcTest(ServiceRoot.self, XPCServiceConfiguration(
///       onPeerAccept: { connection in /* audit hook fires here too */ }))
///     defer { service.close() }
///     let root = try await service.channel.retrying {
///       try await service.channel.root.ping()
///     }
///
/// Coordinators are fully isolated from one another — parallel-safe, no
/// shared `.root` identity, no shared shutdown bridge — and each serves a
/// fresh root. The process-global `XPCRootActor.shared` singleton
/// (production semantics) is exercised by hosting `XPCRootActorServer`
/// directly instead.
///
/// The client side is a full production `XPCRootConnection` — `root`,
/// `events`, and `retrying` behave exactly as against a launchd service,
/// with one documented difference: the channel dials the coordinator's own
/// listener endpoint, so it survives peer drops (transparent re-dial) but
/// dies permanently when the coordinator closes. Only a named-service
/// connection also survives a full service restart. `dropServerPeer()`
/// surfaces as `.disconnected` on `channel.events`.
///
/// The test-only operations live here, not on the channel: `host` exposes
/// the service host (cooperative `requestShutdown()` plus the shutdown
/// completion for exit-policy assertions), `makeClient()` dials additional
/// clients, and `close()` tears everything down. Nothing ever exits the
/// process.
@available(macOS 15, *)
public final class XPCRootTestCoordinator<Root: XPCRootActor>: @unchecked Sendable {
  /// The client side of the channel: a production `XPCRootConnection`
  /// dialed against the coordinator's endpoint.
  public let channel: XPCRootConnection<Root>
  /// The service host driving the coordinator's peers and shutdown
  /// pipeline.
  public let host: XPCServiceHost

  private let listener: XPCConnection
  private let system: XPCDistributedActorSystem
  private let closed = Mutex(false)

  /// Retains the latest server-side peer so tests can simulate the service
  /// dropping a client.
  private final class ServerPeerBox: @unchecked Sendable {
    let peer = Mutex<XPCConnection?>(nil)
  }
  private let serverPeer: ServerPeerBox

  init(
    _ rootType: Root.Type,
    _ delegate: some XPCServiceDelegate
  ) throws {
    let processConnection = XPCConnection(name: nil)
    processConnection.setEventHandler { _ in }
    processConnection.activate()
    let system = XPCDistributedActorSystem(
      connection: processConnection,
      ownsConnection: true,
      allowsChildReclamation: true)
    system.reserveRootID()
    let root = Root(actorSystem: system)

    let host = XPCServiceHost(delegate)
    host.setPeerHandler { [weak host] connection in
      system.setServiceShutdownHandler { [weak host] in host?.requestShutdown() }
      system.bind(connection, to: root)
    }

    let listener = XPCConnection(name: nil)
    let serverPeer = ServerPeerBox()
    listener.setEventHandler { object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      let peer = XPCConnection(xpc_object: object.xpc_object)
      serverPeer.peer.withLock { $0 = peer }
      host.accept(peer)
    }
    listener.activate()

    let endpoint = try XPCConnection.unmarshal(from: listener.marshal())
    let channel = try XPCRootConnection<Root>.connect(using: endpoint)
    self.listener = listener
    self.system = system
    self.host = host
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
  /// `events`; because it dials the coordinator's *listener* endpoint,
  /// libxpc transparently re-dials while the coordinator lives and the
  /// host accepts a fresh session. Permanent channel death requires
  /// `close()`. A no-op while no peer has been accepted.
  public func dropServerPeer() {
    serverPeer.peer.withLock { $0 }?.cancel()
  }

  /// Idempotently tears the coordinator down: the client channel, the
  /// listener, the service host, and the simulated process's actor system.
  /// Also runs from `deinit`.
  public func close() {
    let first = closed.withLock { state -> Bool in
      if state { return false }
      state = true
      return true
    }
    guard first else { return }
    channel.close()
    listener.cancel()
    host.cancel()
    system.invalidate()
  }

  deinit { close() }
}

/// Spawns a coordinated in-process test service serving a **fresh
/// instance** of `rootType` over an anonymous listener and returns the
/// coordinator pairing it with a production client channel. Never exits
/// the process; see `XPCRootTestCoordinator` for lifetime, isolation, and
/// connection-model details.
///
/// The delegate semantics are identical to the hosted `xpcMain` entry point
/// — hooks and code signing requirements behave the same — with two
/// deliberate differences: nothing exits the process, and the served root
/// is coordinator-local, not the process-global `XPCRootActor.shared`.
///
/// - Parameters:
///   - rootType: the concrete root actor type served on the channel.
///   - delegate: the service customization; typically an
///     `XPCServiceConfiguration` whose closures record side effects for
///     assertions.
@available(macOS 15, *)
public func xpcTest<Root: XPCRootActor>(
  _ rootType: Root.Type,
  _ delegate: some XPCServiceDelegate = XPCServiceConfiguration()
) throws -> XPCRootTestCoordinator<Root> {
  try XPCRootTestCoordinator(rootType, delegate)
}
