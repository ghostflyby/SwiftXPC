// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftXPC
import Synchronization

/// Owns one root, its registry, and the service host. The backend-specific
/// delegate governs both native admission and service lifecycle.
/// Retain the service for its entire serving lifetime; it owns its listeners.
/// Keeping only the host or root does not retain the service.
public final class XPCActorService<Root: XPCRootActor>: Sendable {
  public let root: Root
  public let host: XPCServiceHost
  let system: XPCDistributedActorSystem
  private let acceptorFactory: @Sendable (String?) throws -> XPCChannelAcceptor

  private let listeners: ListenerStore

  private final class ListenerStore: Sendable {
    struct State {
      var cancelled = false
      var listeners: [XPCChannelAcceptor] = []
    }
    private let state = Mutex(State())

    func insert(_ listener: XPCChannelAcceptor) throws {
      let inserted = state.withLock { state in
        guard !state.cancelled else { return false }
        state.listeners.append(listener)
        return true
      }
      if !inserted {
        listener.cancel()
        throw XPCChannelError.invalid
      }
    }

    func cancel() {
      let listeners = state.withLock { state in
        state.cancelled = true
        let listeners = state.listeners
        state.listeners = []
        return listeners
      }
      for listener in listeners { listener.cancel() }
    }
  }

  public convenience init(
    _ rootType: Root.Type = Root.self,
    _ delegate: some XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
    eventLog: XPCServiceEventLog? = nil,
    onShutdown: @escaping @Sendable () -> Void = {},
    makeRoot: (XPCDistributedActorSystem) -> Root = { Root(actorSystem: $0) }
  ) {
    self.init(
      rootType, delegate: delegate, transport: .cConnection, eventLog: eventLog,
      acceptorFactory: { try XPCChannelAcceptor(delegate, service: $0, eventLog: eventLog) },
      onShutdown: onShutdown, makeRoot: makeRoot)
  }

  public convenience init(
    _ rootType: Root.Type = Root.self,
    sessionDelegate: some XPCSessionServiceDelegate,
    eventLog: XPCServiceEventLog? = nil,
    onShutdown: @escaping @Sendable () -> Void = {},
    makeRoot: (XPCDistributedActorSystem) -> Root = { Root(actorSystem: $0) }
  ) {
    self.init(
      rootType, delegate: sessionDelegate, transport: .session, eventLog: eventLog,
      acceptorFactory: {
        try XPCChannelAcceptor(sessionDelegate: sessionDelegate, service: $0, eventLog: eventLog)
      }, onShutdown: onShutdown, makeRoot: makeRoot)
  }

  /// Runtime backend selection with default admission. Custom admission uses
  /// a backend-specific initializer, preventing mismatched delegate/transport pairs.
  public convenience init(
    _ rootType: Root.Type = Root.self,
    transport: XPCChannelTransport,
    eventLog: XPCServiceEventLog? = nil,
    makeRoot: (XPCDistributedActorSystem) -> Root = { Root(actorSystem: $0) }
  ) {
    switch transport {
    case .cConnection: self.init(rootType, eventLog: eventLog, makeRoot: makeRoot)
    case .session:
      self.init(
        rootType, sessionDelegate: XPCSessionServiceConfiguration(),
        eventLog: eventLog, makeRoot: makeRoot)
    }
  }

  private init(
    _ rootType: Root.Type,
    delegate: some XPCServiceDelegate,
    transport: XPCChannelTransport,
    eventLog: XPCServiceEventLog?,
    acceptorFactory: @escaping @Sendable (String?) throws -> XPCChannelAcceptor,
    onShutdown: @escaping @Sendable () -> Void,
    makeRoot: (XPCDistributedActorSystem) -> Root
  ) {
    let system = XPCDistributedActorSystem(transport: transport)
    system.reserveRootID()
    let root = makeRoot(system)
    precondition(
      root.id == .root && root.actorSystem === system,
      "The root factory must construct the first actor on the supplied system")
    let listeners = ListenerStore()
    let host = XPCServiceHost(
      delegate, eventLog: eventLog,
      peerHandler: { [weak system, weak root] channel in
        guard let system, let root else { throw XPCChannelError.invalid }
        system.bind(channel, to: root)
      },
      onShutdown: { [weak system] in
        listeners.cancel()
        system?.invalidate()
        onShutdown()
      })
    self.system = system
    self.root = root
    self.host = host
    self.acceptorFactory = acceptorFactory
    self.listeners = listeners
    system.setServiceShutdownHandler { [weak host] in host?.requestShutdown() }
  }

  func makeAcceptor(service: String? = nil) throws -> XPCChannelAcceptor {
    let acceptor = try acceptorFactory(service)
    try listeners.insert(acceptor)
    return acceptor
  }

  /// Creates, routes, and activates a listener using this service's delegate.
  /// The service retains it and closes it during cancellation or shutdown.
  @discardableResult
  public func listen(service: String? = nil) throws -> XPCChannelAcceptor {
    let acceptor = try makeAcceptor(service: service)
    acceptor.setAcceptHandler { [host] in host.bind($0) }
    try acceptor.activate()
    return acceptor
  }

  public func cancel() {
    listeners.cancel()
    host.cancel()
    system.invalidate()
  }

  deinit { cancel() }
}
