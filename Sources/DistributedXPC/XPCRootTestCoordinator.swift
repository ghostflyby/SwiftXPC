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
///     let root = try await service.client.retrying { _ in
///       try await service.client.root.ping()
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
/// surfaces as `.disconnected` on `client.events`.
///
/// The test-only operations live here, not on the channel: `host` exposes
/// the service host (cooperative `requestShutdown()` plus the shutdown
/// completion for exit-policy assertions), `makeClient()` dials additional
/// clients, and `close()` tears everything down. Nothing ever exits the
/// process.
@available(macOS 15, *)
public final class XPCRootTestCoordinator<Root: XPCRootActor>: @unchecked Sendable {
  /// The default client: a production `XPCRootConnection` dialed against
  /// the coordinator's endpoint at spawn time — `root` for calls, `events`
  /// for disconnects, `retrying` for restarts.
  public let client: XPCRootConnection<Root>
  /// The service host driving the coordinator's peers and shutdown
  /// pipeline.
  public let host: XPCServiceHost

  private let listener: XPCConnection
  private let system: XPCDistributedActorSystem
  private let eventLog: XPCServiceEventLog?
  private let closed = Mutex(false)
  private let closeLock = NSLock()
  private var closeNotified = false
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var watchdog: DispatchWorkItem?

  /// Retains the latest server-side peer so tests can simulate the service
  /// dropping a client.
  private final class ServerPeerBox: @unchecked Sendable {
    let peer = Mutex<XPCConnection?>(nil)
  }
  private let serverPeer: ServerPeerBox

  /// - Parameters:
  ///   - rootType: the concrete root actor type served on the channel.
  ///   - delegate: the connection-lifecycle customization.
  ///   - eventLog: when non-nil, every delegate-hook invocation is recorded
  ///     into it for hook-order and count assertions.
  ///   - watchdog: when non-nil, the coordinator force-closes itself after
  ///     this duration so a hung test fails fast (pending calls observe the
  ///     channel going down) instead of blocking the suite. The watchdog
  ///     fires from a global queue; `close()` cancels it.
  init(
    _ rootType: Root.Type,
    _ delegate: some XPCServiceDelegate,
    eventLog: XPCServiceEventLog?,
    watchdog: Duration?
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

    let host = XPCServiceHost(delegate, eventLog: eventLog)
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
    let client = try XPCRootConnection<Root>.connect(using: endpoint)
    self.listener = listener
    self.system = system
    self.eventLog = eventLog
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

  /// Deterministically waits until the delegate hook for `kind` has been
  /// invoked `occurrence` times and returns that occurrence's event
  /// (`occurrence: 2` waits for the second). Returns immediately when
  /// already recorded; returns `nil` when `timeout` elapses first or when
  /// the coordinator was spawned without an `eventLog`. Never polls.
  public func expectEvent(
    _ kind: XPCServiceEvent.Kind,
    occurrence: Int = 1,
    timeout: Duration? = nil
  ) async -> XPCServiceEvent? {
    guard let eventLog else { return nil }
    guard
      await eventLog.expectCount(
        kind, atLeast: occurrence, timeout: timeout
      )
    else { return nil }
    return eventLog.events.filter { $0.kind == kind }[occurrence - 1]
  }

  /// Deterministically waits until a cooperative shutdown has run
  /// (`requestShutdown()`, or `XPCDistributedActorSystem
  /// .requestServiceShutdown()` from actor code), returning `true`;
  /// `false` when `timeout` elapses first. Never polls.
  public func waitForShutdown(timeout: Duration? = nil) async -> Bool {
    await host.expectShutdown(timeout: timeout)
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
    watchdog?.cancel()
    client.close()
    listener.cancel()
    host.cancel()
    system.invalidate()
    notifyClosed()
  }

  private func notifyClosed() {
    closeLock.lock()
    closeNotified = true
    let waiters = closeWaiters
    closeWaiters.removeAll()
    closeLock.unlock()
    waiters.forEach { $0.resume() }
  }

  /// Deterministically waits until the coordinator has been closed — by
  /// \`close()\`, the watchdog, or deinit — and everything it owned has been
  /// torn down. Returns immediately when already closed. Never polls.
  public func waitUntilClosed() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      closeLock.lock()
      if closeNotified {
        closeLock.unlock()
        cont.resume()
        return
      }
      closeWaiters.append(cont)
      closeLock.unlock()
    }
  }
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
///   - eventLog: when non-nil, every delegate-hook invocation is recorded
///     into it for hook-order and count assertions.
///   - watchdog: when non-nil, the coordinator force-closes itself after
///     this duration so a hung test fails fast (pending calls observe the
///     channel going down) instead of blocking the suite.
@available(macOS 15, *)
public func xpcTest<Root: XPCRootActor>(
  _ rootType: Root.Type,
  _ delegate: some XPCServiceDelegate = XPCServiceConfiguration(),
  eventLog: XPCServiceEventLog? = nil,
  watchdog: Duration? = nil
) throws -> XPCRootTestCoordinator<Root> {
  try XPCRootTestCoordinator(rootType, delegate, eventLog: eventLog, watchdog: watchdog)
}
