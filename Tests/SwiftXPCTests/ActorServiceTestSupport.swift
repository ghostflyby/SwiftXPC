// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DistributedXPC
import SwiftXPC
import XPC

/// Fixture-only default construction; production roots have no initializer requirement.
protocol TestRoot: XPCRootActor {
  init(actorSystem: XPCDistributedActorSystem)
}

/// Bridges existing raw-host fixtures into typed lifecycle tests. The public
/// actor-service API itself accepts only backend-specific typed delegates.
struct TestActorDelegate<Root: XPCRootActor>: XPCConnectionActorServiceDelegate,
  XPCSessionActorServiceDelegate
{
  let factory: @Sendable (XPCDistributedActorSystem) async throws -> Root
  var c: any XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration()
  var s: any XPCSessionServiceDelegate = XPCSessionServiceConfiguration()
  var transport = XPCChannelTransport.cConnection
  var completion: @Sendable () -> Void = {}

  func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> Root {
    try await factory(actorSystem)
  }
  var peerCodeSigningRequirement: String? { c.peerCodeSigningRequirement }
  func shouldAcceptConnection(_ connection: XPCConnection, in service: XPCActorService<Root>)
    throws -> Bool
  { try c.shouldAcceptConnection(connection) }
  func didRejectConnection(
    _ connection: XPCConnection, in service: XPCActorService<Root>, error: (any Error)?
  ) { c.didRejectConnection(connection, error: error) }
  func shouldAcceptSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<Root>
  ) throws -> Bool { try s.shouldAcceptSessionRequest(request) }
  func didRejectSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<Root>,
    error: (any Error)?
  ) { s.didRejectSessionRequest(request, error: error) }
  private var raw: any XPCServiceDelegate { transport == .cConnection ? c : s }
  func peerDidBind(_ peer: XPCChannel, to service: XPCActorService<Root>) async {
    raw.didAcceptPeer(peer)
  }
  func peerDidFailToBind(
    _ peer: XPCChannel, to service: XPCActorService<Root>, error: any Error
  ) async { raw.didRejectPeer(peer, error: error) }
  func peerDidEnd(_ peer: XPCChannel, in service: XPCActorService<Root>) async {
    raw.peerDidEnd(peer)
  }
  func serviceWillShutdown(_ service: XPCActorService<Root>) async throws {
    raw.serviceWillShutdown()
  }
  func serviceDidShutdown(_ service: XPCActorService<Root>, error: (any Error)?) async {
    completion()
  }
}

extension TestActorDelegate where Root: TestRoot {
  init(
    c: any XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
    s: any XPCSessionServiceDelegate = XPCSessionServiceConfiguration(),
    transport: XPCChannelTransport = .cConnection, completion: @escaping @Sendable () -> Void = {}
  ) {
    self.init(
      factory: { Root(actorSystem: $0) }, c: c, s: s,
      transport: transport, completion: completion)
  }
}

func makeTestService<Root: TestRoot>(
  _ root: Root.Type,
  _ delegate: any XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
  transport: XPCChannelTransport = .cConnection,
  eventLog: XPCServiceEventLog? = nil,
  makeRoot: @escaping @Sendable (XPCDistributedActorSystem) async throws -> Root = {
    Root(actorSystem: $0)
  }
) async throws -> XPCActorService<Root> {
  let typed = TestActorDelegate(factory: makeRoot, c: delegate, transport: transport)
  switch transport {
  case .cConnection: return try await XPCActorService(typed, eventLog: eventLog)
  case .session: return try await XPCActorService(sessionDelegate: typed, eventLog: eventLog)
  }
}

func testService<Root: TestRoot>(
  _ root: Root.Type,
  _ delegate: any XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
  eventLog: XPCServiceEventLog? = nil, watchdog: Duration? = .seconds(10),
  onShutdown: @escaping @Sendable () -> Void = {}
) async throws -> XPCRootTestCoordinator<Root> {
  try await xpcTest(
    TestActorDelegate<Root>(c: delegate, completion: onShutdown),
    eventLog: eventLog, watchdog: watchdog)
}

func testService<Root: TestRoot>(
  _ root: Root.Type, sessionDelegate: any XPCSessionServiceDelegate,
  eventLog: XPCServiceEventLog? = nil, watchdog: Duration? = .seconds(10),
  onShutdown: @escaping @Sendable () -> Void = {}
) async throws -> XPCRootTestCoordinator<Root> {
  try await xpcTest(
    sessionDelegate: TestActorDelegate<Root>(
      s: sessionDelegate, transport: .session,
      completion: onShutdown),
    eventLog: eventLog, watchdog: watchdog)
}

func testService<Root: TestRoot>(
  _ root: Root.Type, transport: XPCChannelTransport,
  eventLog: XPCServiceEventLog? = nil, watchdog: Duration? = .seconds(10),
  onShutdown: @escaping @Sendable () -> Void = {}
) async throws -> XPCRootTestCoordinator<Root> {
  switch transport {
  case .cConnection:
    return try await testService(
      root, eventLog: eventLog, watchdog: watchdog, onShutdown: onShutdown)
  case .session:
    return try await testService(
      root, sessionDelegate: XPCSessionServiceConfiguration(),
      eventLog: eventLog, watchdog: watchdog, onShutdown: onShutdown)
  }
}
