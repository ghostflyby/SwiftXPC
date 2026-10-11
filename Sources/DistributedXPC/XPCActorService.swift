// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftXPC
import Synchronization
import XPC

/// Owns one root, its registry, listeners, and the typed lifecycle pipeline.
/// Initialization awaits the delegate's factory; `listen` starts serving.
/// Retain this instance for the entire serving lifetime. Keeping only its root
/// or host does not retain the owner. Individual peers do not end the service.
///
/// Cooperative shutdown awaits peer and service hooks before registry cleanup
/// and waiter completion, but does not drain executing RPCs. `cancel`/deinit
/// perform terminal synchronous cleanup without starting asynchronous hooks.
/// Startup and executing hooks retain this owner until they return. Dropping
/// external references cannot stop a suspended hook; cancel the operation or
/// host, and ensure hooks cooperate with cancellation.
public final class XPCActorService<Root: XPCRootActor>: Sendable {
  public let root: Root
  public let host: XPCServiceHost
  let system: XPCDistributedActorSystem

  private enum Admission: Sendable {
    case connection(any XPCConnectionActorServiceDelegate<Root>)
    case session(any XPCSessionActorServiceDelegate<Root>)
  }
  private final class InitialListener: Sendable {
    let value = Mutex<XPCChannelAcceptor?>(nil)
  }
  private enum Phase { case created, starting, running, stopping, finishing, stopped, cancelled }
  private struct State {
    var phase = Phase.created
    var startup: Task<Void, any Error>?
    var listeners: [XPCChannelAcceptor] = []
    var peers: [ObjectIdentifier: Peer] = [:]
    var shutdownError: (any Error)?
  }
  private final class Reference: Sendable {
    struct Value { weak var service: XPCActorService? }
    let value = Mutex(Value())
    var service: XPCActorService? { value.withLock { $0.service } }
  }
  private final class Peer: Sendable {
    let channel: XPCChannel
    let end = XPCServiceReadiness()
    let dispatch = XPCServiceReadiness()
    struct State {
      var ended = false
      var task: Task<Void, Never>?
    }
    let state = Mutex(State())
    init(_ channel: XPCChannel) { self.channel = channel }
    var ended: Bool { state.withLock { $0.ended } }
    func terminate() {
      state.withLock { $0.ended = true }
      dispatch.finish(.failure(XPCChannelError.invalid))
      end.finish(.success(()))
    }
  }
  private struct ConnectionAdmission: XPCConnectionServiceDelegate {
    let delegate: any XPCConnectionActorServiceDelegate<Root>
    let reference: Reference
    var peerCodeSigningRequirement: String? { delegate.peerCodeSigningRequirement }
    func shouldAcceptConnection(_ connection: XPCConnection) throws -> Bool {
      guard let service = reference.service else { return false }
      return try delegate.shouldAcceptConnection(connection, in: service)
    }
    func didRejectConnection(_ connection: XPCConnection, error: (any Error)?) {
      guard let service = reference.service else { return }
      delegate.didRejectConnection(connection, in: service, error: error)
    }
  }
  private struct SessionAdmission: XPCSessionServiceDelegate {
    let delegate: any XPCSessionActorServiceDelegate<Root>
    let reference: Reference
    func shouldAcceptSessionRequest(_ request: XPCListener.IncomingSessionRequest) throws -> Bool {
      guard let service = reference.service else { return false }
      return try delegate.shouldAcceptSessionRequest(request, in: service)
    }
    func didRejectSessionRequest(
      _ request: XPCListener.IncomingSessionRequest, error: (any Error)?
    ) {
      guard let service = reference.service else { return }
      delegate.didRejectSessionRequest(request, in: service, error: error)
    }
  }

  private let delegate: any XPCActorServiceDelegate<Root>
  private let admission: Admission
  private let reference: Reference
  private let eventLog: XPCServiceEventLog?
  private let state = Mutex(State())
  private let readiness = XPCServiceReadiness()

  public convenience init(
    _ delegate: some XPCConnectionActorServiceDelegate<Root>,
    eventLog: XPCServiceEventLog? = nil
  ) async throws {
    try await self.init(
      delegate: delegate, admission: .connection(delegate),
      transport: .cConnection, eventLog: eventLog)
  }

  public convenience init(
    sessionDelegate: some XPCSessionActorServiceDelegate<Root>,
    eventLog: XPCServiceEventLog? = nil
  ) async throws {
    try await self.init(
      delegate: sessionDelegate, admission: .session(sessionDelegate),
      transport: .session, eventLog: eventLog)
  }

  private init(
    delegate: any XPCActorServiceDelegate<Root>, admission: Admission,
    transport: XPCChannelTransport, eventLog: XPCServiceEventLog?
  ) async throws {
    let system = XPCDistributedActorSystem(transport: transport)
    system.suspendServiceDispatch()
    system.reserveRootID()
    let root: Root
    do {
      root = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let root = try await delegate.makeRoot(actorSystem: system)
        try Task.checkCancellation()
        return root
      } onCancel: {
        system.invalidate()
      }
    } catch {
      system.invalidate()
      throw error
    }
    let registeredRoot = try? system.resolve(id: .root, as: Root.self)
    do { try Task.checkCancellation() } catch { system.invalidate(); throw error }
    precondition(
      root.id == .root && root.actorSystem === system && registeredRoot === root,
      "The root factory must construct the first actor on the supplied system")
    let reference = Reference()
    self.system = system
    self.root = root
    self.delegate = delegate
    self.admission = admission
    self.eventLog = eventLog
    self.reference = reference
    host = XPCServiceHost(
      eventLog: eventLog,
      binding: { [reference] channel in
        guard let service = reference.service else { channel.cancel(); return }
        service.enqueue(channel)
      },
      shutdown: { [reference] in reference.service?.beginShutdown() },
      cancellation: { [reference] in reference.service?.cancel() })
    reference.value.withLock { $0.service = self }
    system.setServiceShutdownHandler { [weak host] in host?.requestShutdown() }
  }

  private var aborted: Bool { state.withLock { $0.phase == .cancelled } }
  private var accepting: Bool {
    state.withLock { $0.phase == .starting || $0.phase == .running || $0.phase == .created }
  }
  private func checkServing() throws {
    try Task.checkCancellation()
    guard accepting, host.isAccepting else { throw XPCChannelError.invalid }
  }

  private func makeAcceptor(service: String?) throws -> XPCChannelAcceptor {
    let acceptor: XPCChannelAcceptor
    switch admission {
    case .connection(let delegate):
      acceptor = try XPCChannelAcceptor(
        ConnectionAdmission(delegate: delegate, reference: reference), service: service,
        eventLog: eventLog, handler: { [weak host] in host?.bind($0) })
    case .session(let delegate):
      acceptor = try XPCChannelAcceptor(
        sessionDelegate: SessionAdmission(delegate: delegate, reference: reference),
        service: service,
        eventLog: eventLog, handler: { [weak host] in host?.bind($0) })
    }
    let inserted = state.withLock { state in
      guard state.phase == .starting || state.phase == .running else { return false }
      state.listeners.append(acceptor)
      return true
    }
    guard inserted else { acceptor.cancel(); throw XPCChannelError.invalid }
    return acceptor
  }

  private func addListener(
    service: String?, activation: @Sendable (XPCChannelAcceptor) throws -> Void
  ) throws -> XPCChannelAcceptor {
    try checkServing()
    let acceptor = try makeAcceptor(service: service)
    do {
      try activation(acceptor)
      try checkServing()
      return acceptor
    } catch {
      acceptor.cancel()
      let removed = state.withLock { state in
        let removed = state.listeners.filter { $0 === acceptor }
        state.listeners.removeAll { $0 === acceptor }
        return removed
      }
      withExtendedLifetime(removed) {}
      throw error
    }
  }

  /// The first listener awaits both startup hooks. Subsequent listeners share
  /// the running service; their failure does not retire existing listeners.
  /// Concurrent first calls share one startup operation. Do not call this
  /// from a startup hook, which would wait on its own operation.
  /// Cancellation while any listen call is pending cancels the entire service,
  /// including existing listeners and peers, even when adding another listener.
  /// Already executing hooks must cooperate with cancellation before it returns.
  @discardableResult
  public func listen(service: String? = nil) async throws -> XPCChannelAcceptor {
    try await withTaskCancellationHandler {
      try await listen(service: service, activation: { try $0.activate() })
    } onCancel: {
      self.cancel()
    }
  }

  // Deterministic native-operation failure injection without invalid launchd
  // names, which can abort inside libxpc rather than throw on some SDKs.
  func listen(testingActivation: @escaping @Sendable (XPCChannelAcceptor) throws -> Void)
    async throws -> XPCChannelAcceptor
  {
    try await listen(service: nil, activation: testingActivation)
  }

  private func listen(
    service: String?, activation: @escaping @Sendable (XPCChannelAcceptor) throws -> Void
  ) async throws -> XPCChannelAcceptor {
    let initial = InitialListener()
    let (task, first) = try startTask(
      listener: true, service: service, initial: initial, activation: activation)
    do {
      try await task.value
      try checkServing()
      if first, let listener = initial.value.withLock({ $0 }) { return listener }
      return try addListener(service: service, activation: activation)
    } catch {
      if !accepting { _ = await host.waitForShutdown() }
      throw error
    }
  }

  private func startTask(
    listener: Bool, service: String?, initial: InitialListener? = nil,
    activation: @escaping @Sendable (XPCChannelAcceptor) throws -> Void = { try $0.activate() }
  ) throws
    -> (Task<Void, any Error>, Bool)
  {
    try state.withLock { state in
      switch state.phase {
      case .created:
        state.phase = .starting
        let task = Task {
          try await self.start(
            listener: listener, service: service, initial: initial, activation: activation)
        }
        state.startup = task
        return (task, true)
      case .starting, .running:
        guard let startup = state.startup else { throw XPCChannelError.invalid }
        return (startup, false)
      case .stopping, .finishing, .stopped, .cancelled:
        throw XPCChannelError.invalid
      }
    }
  }

  private func start(
    listener: Bool, service: String?, initial: InitialListener?,
    activation: @Sendable (XPCChannelAcceptor) throws -> Void
  ) async throws {
    do {
      try checkServing()
      try await delegate.serviceWillStart(self)
      try checkServing()
      if listener {
        let acceptor = try addListener(service: service, activation: activation)
        initial?.value.withLock { $0 = acceptor }
      }
      try checkServing()
      await delegate.serviceDidStart(self)
      try checkServing()
      let opened = state.withLock { state in
        guard state.phase == .starting else { return false }
        state.phase = .running
        return true
      }
      guard opened else { throw XPCChannelError.invalid }
      system.resumeServiceDispatch()
      readiness.finish(.success(()))
    } catch {
      readiness.finish(.failure(error))
      host.requestShutdown()
      throw error
    }
  }

  // Native xpc_main owns its listener; its main-thread bootstrap uses the
  // same lifecycle barrier without creating an anonymous listener.
  func startHosted() async throws {
    let (task, _) = try startTask(listener: false, service: nil)
    do { try await task.value } catch { _ = await host.waitForShutdown(); throw error }
  }

  func admitHosted(_ connection: XPCConnection) {
    guard case .connection(let delegate) = admission else { return }
    let adapter = ConnectionAdmission(delegate: delegate, reference: reference)
    guard accepting, host.isAccepting else {
      rejectXPCConnection(connection, delegate: adapter, eventLog: eventLog, error: nil)
      return
    }
    if admitXPCConnection(connection, delegate: adapter, eventLog: eventLog) {
      host.bind(XPCChannel(connection))
    }
  }

  private func enqueue(_ channel: XPCChannel) {
    let peer = Peer(channel)
    channel.addInvalidationHandler { [weak peer] in peer?.terminate() }
    let inserted = state.withLock { state in
      if state.phase == .cancelled { return 0 }
      if state.phase == .stopped || state.phase == .finishing { return 3 }
      if state.peers[ObjectIdentifier(channel)] != nil { return 2 }
      state.peers[ObjectIdentifier(channel)] = peer
      let readiness = self.readiness
      let task = Task { [weak self, peer, readiness] in
        do {
          try await readiness.wait()
          if await self?.prepare(peer) == true {
            try? await peer.end.wait()
            if let self, !self.aborted { await self.delegate.peerDidEnd(channel, in: self) }
          }
        } catch {
          await self?.reject(peer, error: error)
        }
        self?.remove(peer)
      }
      peer.state.withLock { $0.task = task }
      return 1
    }
    if inserted == 0 || inserted == 3 {
      // Cleanup has crossed the peer-hook cutoff: do not launch new business hooks.
      channel.cancel()
      host.recordBindingFailure(XPCChannelError.invalid)
    }
  }

  private func prepare(_ peer: Peer) async -> Bool {
    do {
      try checkServing()
      guard !peer.ended else { throw XPCChannelError.invalid }
      // Install the guarded receive path before user code can activate either
      // native backend. Early messages wait; they cannot be silently dropped.
      system.bind(peer.channel, to: root, readiness: peer.dispatch)
      try await delegate.peerWillBind(peer.channel, to: self)
      try checkServing()
      guard !peer.ended else { throw XPCChannelError.invalid }
      guard host.register(peer.channel, onEnd: { [weak peer] in peer?.terminate() }) else {
        throw XPCChannelError.invalid
      }
      await delegate.peerDidBind(peer.channel, to: self)
      if accepting, !peer.ended, !Task.isCancelled {
        peer.dispatch.finish(.success(()))
        peer.channel.activate()
      } else {
        peer.channel.cancel(); peer.terminate()
      }
      return true
    } catch {
      await reject(peer, error: error)
      return false
    }
  }

  private func reject(_ peer: Peer, error: any Error) async {
    peer.channel.cancel()
    peer.terminate()
    host.recordBindingFailure(error)
    if !aborted { await delegate.peerDidFailToBind(peer.channel, to: self, error: error) }
  }

  private func remove(_ peer: Peer) {
    let removed = state.withLock { $0.peers.removeValue(forKey: ObjectIdentifier(peer.channel)) }
    withExtendedLifetime(removed) {}
  }

  private func beginShutdown() {
    let snapshot = state.withLock {
      state -> (Task<Void, any Error>?, [Peer], [XPCChannelAcceptor])? in
      guard state.phase != .stopping, state.phase != .finishing,
        state.phase != .stopped, state.phase != .cancelled
      else { return nil }
      state.phase = .stopping
      let listeners = state.listeners
      state.listeners = []
      return (state.startup, Array(state.peers.values), listeners)
    }
    guard let (startup, peers, listeners) = snapshot else { return }
    system.stopServiceDispatch()
    readiness.finish(.failure(CancellationError()))
    startup?.cancel()
    for listener in listeners { listener.cancel() }
    for peer in peers {
      peer.state.withLock { $0.task }?.cancel()
      peer.channel.cancel()
      peer.terminate()
    }
    host.cancel()
    Task { await self.shutdown(startup: startup) }
  }

  private func shutdown(startup: Task<Void, any Error>?) async {
    _ = await startup?.result
    while true {
      let tasks = state.withLock { state -> [Task<Void, Never>] in
        let tasks = state.peers.values.compactMap { $0.state.withLock { $0.task } }
        if tasks.isEmpty { state.phase = .finishing }
        return tasks
      }
      if tasks.isEmpty { break }
      for task in tasks { await task.value }
    }
    eventLog?.append(.serviceWillShutdown)
    var error: (any Error)?
    do { try await delegate.serviceWillShutdown(self) } catch let failure { error = failure }
    system.invalidate()
    await delegate.serviceDidShutdown(self, error: error)
    state.withLock {
      $0.phase = .stopped; $0.shutdownError = error
    }
    host.completeShutdown()
  }

  var shutdownFailed: Bool { state.withLock { $0.shutdownError != nil } }
  var startupTask: Task<Void, any Error>? { state.withLock { $0.startup } }

  /// Immediate terminal teardown. Does not start asynchronous hooks or wait
  /// for already executing hooks/RPCs. An existing cooperative shutdown keeps
  /// ownership of cleanup and completes its awaited pipeline instead.
  public func cancel() {
    let snapshot = state.withLock {
      state -> ([Peer], [XPCChannelAcceptor], Task<Void, any Error>?)? in
      switch state.phase {
      case .stopping, .finishing, .stopped, .cancelled: return nil
      case .created, .starting, .running: break
      }
      state.phase = .cancelled
      let retained = (Array(state.peers.values), state.listeners, state.startup)
      state.peers = [:]
      state.listeners = []
      return retained
    }
    guard let (peers, listeners, startup) = snapshot else { return }
    system.stopServiceDispatch()
    readiness.finish(.failure(CancellationError()))
    startup?.cancel()
    for listener in listeners { listener.cancel() }
    for peer in peers {
      peer.state.withLock { $0.task }?.cancel()
      peer.channel.cancel()
      peer.terminate()
    }
    host.cancel()
    system.invalidate()
  }

  deinit { cancel() }
}
