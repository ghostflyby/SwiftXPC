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
///     let service = try await xpcTest(ServiceDelegate(), watchdog: .seconds(10))
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
/// The test-only operations live here, not on the channel: `service.host` exposes
/// the service host (cooperative `requestShutdown()` plus the shutdown
/// completion for exit-policy assertions), `makeClient()` dials additional
/// clients, and `close()` tears everything down. Nothing ever exits the
/// process.
public final class XPCRootTestCoordinator<Root: XPCRootActor>: @unchecked Sendable {
  /// The default client: a production `XPCRootConnection` dialed against
  /// the coordinator's endpoint at spawn time — `root` for calls, `events`
  /// for disconnects, `retrying` for restarts.
  public let client: XPCRootConnection<Root>
  /// The typed service owner, including its local root and lifecycle host.
  public let service: XPCActorService<Root>
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

  init(service: XPCActorService<Root>, watchdog: Duration?) async throws {
    let transport = service.root.actorSystem.transport
    self.transport = transport
    self.service = service
    let host = service.host
    let acceptor = try await service.listen()
    let serverPeer = ServerPeerBox()
    acceptor.setAcceptHandler { channel in
      serverPeer.peer.withLock { $0 = channel }
      host.bind(channel)
    }

    let clientChannel = try transport.channel(dialing: acceptor.wireEndpoint)
    let client = try XPCRootConnection<Root>.connect(using: clientChannel)
    self.acceptor = acceptor
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

/// Starts a production actor service in-process, with an anonymous listener and
/// a root client. Startup hooks complete before return; peer hooks gate RPCs.
/// Access the typed owner through `service`; nothing exits the test process.
/// The watchdog covers factory/startup as well as the serving fixture. Expiry
/// cancels preparation and throws `CancellationError` if startup has not returned.
/// Hooks already executing must honor cooperative cancellation.
public func xpcTest<Root: XPCRootActor>(
  _ delegate: some XPCConnectionActorServiceDelegate<Root>,
  eventLog: XPCServiceEventLog? = nil,
  watchdog: Duration? = nil
) async throws -> XPCRootTestCoordinator<Root> {
  try await makeTestCoordinator(watchdog: watchdog) {
    try await XPCActorService(delegate, eventLog: eventLog)
  }
}

public func xpcTest<Root: XPCRootActor>(
  sessionDelegate: some XPCSessionActorServiceDelegate<Root>,
  eventLog: XPCServiceEventLog? = nil,
  watchdog: Duration? = nil
) async throws -> XPCRootTestCoordinator<Root> {
  try await makeTestCoordinator(watchdog: watchdog) {
    try await XPCActorService(sessionDelegate: sessionDelegate, eventLog: eventLog)
  }
}

private struct WeakTestService<Root: XPCRootActor> {
  weak var service: XPCActorService<Root>?
}

private func makeTestCoordinator<Root: XPCRootActor>(
  watchdog: Duration?,
  factory: @escaping @Sendable () async throws -> XPCActorService<Root>
) async throws -> XPCRootTestCoordinator<Root> {
  let result = XPCServiceResult<XPCRootTestCoordinator<Root>>()
  let owner = Mutex(WeakTestService<Root>())
  let deadline = watchdog.map { ContinuousClock.now + $0 }
  let task = Task {
    do {
      let service = try await factory()
      owner.withLock { $0.service = service }
      do {
        try Task.checkCancellation()
        let remaining = deadline.map { ContinuousClock.now.duration(to: $0) }
        let coordinator = try await XPCRootTestCoordinator(service: service, watchdog: remaining)
        if Task.isCancelled { coordinator.close(); throw CancellationError() }
        result.finish(.success(coordinator))
      } catch {
        service.cancel()
        throw error
      }
    } catch { result.finish(.failure(error)) }
  }
  let timeout: DispatchWorkItem?
  if let watchdog {
    let item = DispatchWorkItem { [weak result] in
      task.cancel()
      owner.withLock { $0.service }?.cancel()
      result?.finish(.failure(CancellationError()))
    }
    timeout = item
    let seconds =
      Double(watchdog.components.seconds) + Double(watchdog.components.attoseconds) * 1e-18
    DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds), execute: item)
  } else {
    timeout = nil
  }
  defer { timeout?.cancel() }
  let coordinator = try await withTaskCancellationHandler {
    try await result.wait()
  } onCancel: {
    task.cancel()
    owner.withLock { $0.service }?.cancel()
    result.finish(.failure(CancellationError()))
  }
  if Task.isCancelled { coordinator.close(); throw CancellationError() }
  return coordinator
}
