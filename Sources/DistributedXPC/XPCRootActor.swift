// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC
import Synchronization

/// Marks a concrete distributed actor as the bootstrap entry point of an
/// XPC service: the actor is a process-wide singleton hosted on the
/// long-lived service host system, and every accepted peer channel binds to
/// `shared` under `XPCActorID.root` — the one-instance-per-process shape of
/// a typical XPC service. Clients obtain it via `connect(toService:)` /
/// `connect(using:)`.
///
/// Conformance is nearly free: `init(actorSystem:)` plus the export
/// metadata are all a bare root needs — `shared` has a default
/// implementation that lazily creates and caches
/// `Self(actorSystem: .serviceHost)`. Override `shared` when construction
/// needs dependencies:
///
///     private let sharedRoot = ServiceRoot(greeter: Greeter(), actorSystem: .serviceHost)
///     extension ServiceRoot: XPCRootActor {
///       static var shared: ServiceRoot { sharedRoot }
///     }
///
/// Services that need per-connection behavior build it on top of the
/// singleton: hand out child actors from `shared`'s methods, or route by
/// peer identity inside the delegate's `didAcceptPeer`.
public protocol XPCRootActor: XPCExportableActor,
  XPCDistributedTargetMetadataProviding
{
  init(actorSystem: XPCDistributedActorSystem)

  /// The process-wide singleton root. Prefer the default implementation;
  /// override with a computed property over a file-scoped constant when
  /// construction needs dependencies — a `static let` stored on the actor
  /// itself cannot call `init(actorSystem:)` under Swift 6 strict
  /// concurrency:
  ///
  ///     private let sharedRoot = ServiceRoot(actorSystem: .serviceHost)
  ///     extension ServiceRoot: XPCRootActor {
  ///       static var shared: ServiceRoot { sharedRoot }
  ///     }
  ///
  /// Materializing `shared` before the first connection is safe: the host
  /// system reserves the `.root` identity at creation, so the singleton
  /// keeps that identity regardless of creation order. Its registry entry
  /// is never reclaimed.
  static var shared: Self { get }
}

/// Cache behind the default `shared`. A `~Copyable` struct over a `Mutex`:
/// protocols cannot hold static stored properties, and a noncopyable
/// registry cannot be aliased into a second mutable copy.
private struct SharedRootRegistry: Sendable, ~Copyable {
  private let roots: Mutex<[ObjectIdentifier: any XPCRootActor]> = .init([:])

  func root<R: XPCRootActor>(for rootType: R.Type) -> R {
    let key = ObjectIdentifier(rootType)
    if let existing = roots.withLock({
      $0[key]
    }) {
      return existing as! R
    }
    let created = R(actorSystem: .serviceHost)
    roots.withLock {
      $0[key] = created
    }
    return created
  }
}

private let sharedRootRegistry = SharedRootRegistry()

extension XPCRootActor {
  /// The process-wide singleton root, lazily created and cached on the
  /// long-lived service host system. Concurrent first accesses race to
  /// create; the cache guarantees exactly one surviving instance.
  public static var shared: Self {
    sharedRootRegistry.root(for: Self.self)
  }
}

extension XPCServiceHost {
  /// Serves `rootType`'s process-wide singleton on every accepted peer:
  /// the installed peer handler binds each connection to `Root.shared`
  /// under `XPCActorID.root`. This is the in-process root-actor host used
  /// by `xpcMain`/`XPCApp.main()`, and it is available directly to
  /// embedders and tests that drive `accept(_:)` themselves.
  ///
  /// - Parameters:
  ///   - rootType: the concrete root actor type served on every accepted
  ///     peer; only its `shared` singleton is ever constructed.
  ///   - delegate: the connection-lifecycle customization; see
  ///     `XPCServiceDelegate` for the per-hook semantics. Defaults to a
  ///     plain `XPCServiceConfiguration`.
  ///   - eventLog: when non-nil, the host records every delegate-hook
  ///     invocation into it, in invocation order.
  public convenience init<Root: XPCRootActor>(
    _ rootType: Root.Type = Root.self,
    _ delegate: some XPCServiceDelegate = XPCServiceConfiguration(),
    eventLog: XPCServiceEventLog? = nil
  ) {
    self.init(delegate, eventLog: eventLog)
    setPeerHandler { [weak self] connection in
      let serviceHost = XPCDistributedActorSystem.serviceHost
      // Reserve before the first `shared` access so lazy creation assigns
      // the reserved identity (one root actor type per process).
      serviceHost.reserveRootID()
      // Actors of the singleton reach the cooperative shutdown path through
      // the host system; a weak reference avoids a server <-> system cycle.
      serviceHost.setServiceShutdownHandler { [weak self] in self?.requestShutdown() }
      let root = Root.shared
      // Programming-error guard: if anything else on the service host
      // consumed the `.root` identity before the singleton was created,
      // refuse the peer instead of silently misrouting every call
      // addressed to `.root`. Throwing rejects the peer through the host's
      // standard rejection path.
      guard root.id == .root else {
        throw XPCDispatchError.unknownActor(.root)
      }
      serviceHost.bind(connection, to: root)
    }
  }
}

/// The SwiftUI-`App`-style entry point: a type carrying both the service's
/// root actor and its delegate customization, marked `@main` directly.
///
///     @main
///     struct AgentService: XPCApp {
///       typealias Root = ServiceRoot
///
///       var peerCodeSigningRequirement: String? { "identifier \"com.example.agent\"" }
///       func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool {
///         connection.euid == 501
///       }
///     }
///
/// The type must be constructible with no arguments: the library-provided
/// `main()` hosts a fresh instance as the delegate of an `XPCServiceHost`
/// serving `Root.shared`, and exits the process after a cooperative
/// shutdown. All customization lives in the conformer's own requirement
/// implementations, exactly as in `xpcMain`.
public protocol XPCApp: XPCServiceDelegate {
  /// The singleton root actor type served by the app.
  associatedtype Root: XPCRootActor

  /// Creates the delegate for hosting.
  init()

  /// Runs the XPC service event loop with `Self` as the delegate. Never
  /// returns. Provided by the library; this is the `@main` entry point.
  @MainActor static func main()
}

extension XPCApp {
  @MainActor
  public static func main() {
    xpcMain(Self.Root.self, Self())
  }
}

/// Runs the XPC service event loop with default service behavior, serving
/// `rootType`'s singleton on every accepted peer connection. Never returns.
/// Must run on the main thread.
///
/// Equivalent to `xpcMain(rootType, XPCServiceConfiguration())`: peers are
/// accepted unconditionally unless gated by a `peerCodeSigningRequirement`.
/// Customize via the delegate overload, or mark a delegate type `@main`
/// via `XPCApp`.
///
/// The hosted entry point only ever runs as a launchd-managed standalone
/// service process (`xpc_main` aborts anywhere else), so a cooperative
/// shutdown unconditionally ends the process: see the delegate overload.
/// For in-process hosting — tests and embedders — use `xpcTest(_:_:)` or a
/// standalone `XPCServiceHost(rootType, delegate)`, neither of which ever
/// exits the process.
@MainActor
public func xpcMain<Root>(
  _ rootType: Root.Type,
  _ delegate: any XPCServiceDelegate = XPCServiceConfiguration()
) -> Never where Root: XPCRootActor {
  let server = XPCServiceHost(rootType, delegate)
  // The hosted service *is* the process: retire it right after the
  // delegate's shutdown hook has run.
  server.setShutdownCompletion { exit(0) }
  delegate.serviceWillStart(host: server)
  return SwiftXPC.xpcMain { connection in server.accept(connection) }
}

extension XPCRootActor {
  /// Connects to a launchd-managed XPC service by mach service name and
  /// resolves its root actor.
  ///
  /// - Parameters:
  ///   - serviceName: the launchd mach service name of the service.
  ///   - peerCodeSigningRequirement: kernel-enforced requirement the service
  ///     must satisfy, installed on the connection before activation. A
  ///     service failing it is dropped by XPC; a requirement that cannot be
  ///     installed makes `connect` throw (fail-closed).
  public static func connect(
    toService serviceName: String,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try connect(
      using: XPCConnection(name: serviceName),
      peerCodeSigningRequirement: peerCodeSigningRequirement)
  }

  /// Connects through an existing connection. Note: only connections to a
  /// *named* mach service re-establish after a service restart; endpoint-based
  /// connections die permanently with the peer.
  ///
  /// `peerCodeSigningRequirement` authenticates the service and must be
  /// installed on a *not-yet-activated* connection. On an already-activated
  /// connection the install reports success but the channel then fails to
  /// establish (hangs or interrupts) — pass a fresh connection.
  public static func connect(
    using connection: XPCConnection,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try connection.applyPeerCodeSigningRequirement(peerCodeSigningRequirement)
    let system = XPCDistributedActorSystem(connection: connection, ownsConnection: true)
    connection.activate()
    return try Self.resolve(id: .root, using: system)
  }
}

extension XPCConnection {
  /// Installs `requirement` on this connection when non-nil. Must run before
  /// activation; an install failure propagates so callers can fail closed.
  func applyPeerCodeSigningRequirement(
    _ requirement: String?
  ) throws(XPCConnection.PeerRequirementError) {
    guard let requirement else { return }
    try setPeerCodeSigningRequirement(requirement)
  }
}
