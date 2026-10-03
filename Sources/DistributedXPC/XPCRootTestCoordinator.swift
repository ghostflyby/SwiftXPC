// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization

/// Owns a production `XPCActorService`, an anonymous listener, and a client
/// connection. Each coordinator has an independent root and actor registry.
/// Additional clients share that coordinator's root.
///
///     let service = try xpcTest(ServiceRoot.self, XPCConnectionServiceConfiguration(
///       onPeerAccept: { connection in /* audit hook fires here too */ }))
///     defer { service.close() }
///     let root = try await service.client.retrying { _ in
///       try await service.client.root.ping()
///     }
///
/// The client side is a full production `XPCRootConnection` — `root`,
/// `events`, and `retrying` behave exactly as against a launchd service,
/// with one documented difference: the channel dials the coordinator's own
/// listener endpoint. C channels survive peer drops through transparent re-dial;
/// Session channels are terminal after a drop. Both end when the coordinator
/// closes. Only a named C service connection survives a full service restart.
/// `dropServerPeer()` surfaces as `.disconnected` on `client.events`.
///
/// The test-only operations live here, not on the channel: `host` exposes
/// the service host (cooperative `requestShutdown()` plus the shutdown
/// completion for exit-policy assertions), `makeClient()` dials additional
/// clients, and `close()` tears everything down. Nothing ever exits the
/// process.
public final class XPCRootTestCoordinator<Root: XPCRootActor>: @unchecked Sendable {
  /// The default client: a production `XPCRootConnection` dialed against
  /// the coordinator's endpoint at spawn time — `root` for calls, `events`
  /// for disconnects, `retrying` for restarts.
  public let client: XPCRootConnection<Root>
  /// The service host driving the coordinator's peers and shutdown
  /// pipeline.
  public let host: XPCServiceHost
  /// The backend the coordinator serves and dials with.
  private let service: XPCActorService<Root>
  public let transport: XPCChannelTransport

  private let acceptor: XPCChannelAcceptor
  private let closed = Mutex(false)
  private struct CloseWaiterState: Sendable {
    var notified = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let closeState = Mutex(CloseWaiterState())
  private var watchdog: DispatchWorkItem?

  /// Retains the latest server-side peer so tests can simulate the service
  /// dropping a client.
  private final class ServerPeerBox: Sendable {
    let peer = Mutex<(XPCChannel)?>(nil)
  }
  private let serverPeer: ServerPeerBox

  init(service: XPCActorService<Root>, watchdog: Duration?) throws {
    let transport = service.root.actorSystem.transport
    self.transport = transport
    self.service = service
    let host = service.host
    let acceptor = try service.makeAcceptor()
    let serverPeer = ServerPeerBox()
    acceptor.setAcceptHandler { channel in
      serverPeer.peer.withLock { $0 = channel }
      host.bind(channel)
    }
    try acceptor.activate()

    let clientChannel = try transport.channel(dialing: acceptor.wireEndpoint)
    let client = try XPCRootConnection<Root>.connect(using: clientChannel)
    self.acceptor = acceptor
    self.host = host
    self.client = client
    self.serverPeer = serverPeer

    // Scheduled last: `self` may only be captured once every stored
    // property is initialized.
    self.watchdog = nil
    guard let watchdog else { return }
    let item = DispatchWorkItem { [weak self] in self?.close() }
    self.watchdog = item
    let seconds =
      Double(watchdog.components.seconds)
      + Double(watchdog.components.attoseconds) * 1e-18
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
  }

  /// Dials a fresh, inactive client channel to the same acceptor, for
  /// tests that exercise multiple sequential or concurrent clients against
  /// one service. Endpoint-based like every channel here: activate it
  /// via `Root.connect(using:)` or manually. C channels can re-dial after a
  /// peer drop; Session channels end permanently.
  public func makeClient() throws -> XPCChannel {
    try transport.channel(dialing: acceptor.wireEndpoint)
  }

  /// Cancels the latest accepted server-side peer, as if the service had
  /// dropped that client. The client channel observes `.disconnected` on
  /// `events`. On the C backend, libxpc transparently re-dials the
  /// coordinator's listener endpoint while the coordinator lives and the
  /// host accepts a fresh session; the session backend never re-dials
  /// (probed: the dropped session channel is terminal), so the client dies
  /// permanently with the drop — use `.cConnection` for reconnection
  /// tests. A no-op while no peer has been accepted.
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
    watchdog?.cancel()
    client.close()
    acceptor.cancel()
    service.cancel()
    notifyClosed()
  }

  private func notifyClosed() {
    let waiters =
      closeState.withLock { closeState -> [CheckedContinuation<Void, Never>] in
        closeState.notified = true
        let waiters = closeState.waiters
        closeState.waiters.removeAll()
        return waiters
      }
    waiters.forEach { $0.resume() }
  }

  /// Deterministically waits until the coordinator has been closed — by
  /// `close()`, the watchdog, or deinit — and everything it owned has been
  /// torn down. Returns immediately when already closed. Never polls.
  public func waitUntilClosed() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      let alreadyClosed = closeState.withLock { closeState -> Bool in
        if closeState.notified {
          return true
        }
        closeState.waiters.append(cont)
        return false
      }
      if alreadyClosed {
        cont.resume()
      }
    }
  }

  deinit { close() }
}

/// Owns an in-process service, anonymous listener, and production root client.
/// Use a backend-specific delegate for native admission. Event waiting belongs
/// to `XPCServiceEventLog.wait`; shutdown waiting belongs to `service.host`.
public func xpcTest<Root: XPCRootActor>(
  _ rootType: Root.Type,
  _ delegate: some XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
  eventLog: XPCServiceEventLog? = nil,
  watchdog: Duration? = nil,
  onShutdown: @escaping @Sendable () -> Void = {}
) throws -> XPCRootTestCoordinator<Root> {
  try XPCRootTestCoordinator(
    service: XPCActorService(rootType, delegate, eventLog: eventLog, onShutdown: onShutdown),
    watchdog: watchdog)
}

public func xpcTest<Root: XPCRootActor>(
  _ rootType: Root.Type,
  sessionDelegate: some XPCSessionServiceDelegate,
  eventLog: XPCServiceEventLog? = nil,
  watchdog: Duration? = nil,
  onShutdown: @escaping @Sendable () -> Void = {}
) throws -> XPCRootTestCoordinator<Root> {
  try XPCRootTestCoordinator(
    service: XPCActorService(
      rootType, sessionDelegate: sessionDelegate, eventLog: eventLog, onShutdown: onShutdown),
    watchdog: watchdog)
}

/// Runtime backend selection with default admission, useful for transport matrices.
public func xpcTest<Root: XPCRootActor>(
  _ rootType: Root.Type,
  transport: XPCChannelTransport,
  eventLog: XPCServiceEventLog? = nil,
  watchdog: Duration? = nil,
  onShutdown: @escaping @Sendable () -> Void = {}
) throws -> XPCRootTestCoordinator<Root> {
  try XPCRootTestCoordinator(
    service: XPCActorService(
      rootType, transport: transport, eventLog: eventLog, onShutdown: onShutdown),
    watchdog: watchdog
  )
}
