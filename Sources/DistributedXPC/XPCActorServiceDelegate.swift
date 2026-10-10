// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftXPC
import XPC

/// Typed lifecycle of one actor service. The factory runs once; all other
/// hooks default to no-ops. Hooks run outside framework locks, without a
/// prescribed executor. Service stages are serial, and peer stages are serial
/// per channel; different peers may run concurrently.
///
/// Startup and binding hooks gate dispatch. Do not await an RPC through the
/// service/channel whose gate you are preparing, or wait for shutdown from a
/// hook that shutdown itself must await. Throw from a will-hook to report
/// preparation failure. Cancellation requires cooperative asynchronous hooks.
public protocol XPCActorServiceDelegate<Root>: Sendable {
  associatedtype Root: XPCRootActor
  /// Construct the first actor on this system, using any injected dependencies.
  func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> Root
  /// The root exists; listeners and business dispatch are not yet open.
  func serviceWillStart(_ service: XPCActorService<Root>) async throws
  /// Native reception is configured; business dispatch opens after this returns.
  func serviceDidStart(_ service: XPCActorService<Root>) async
  /// An admitted peer awaits business authorization and preparation.
  func peerWillBind(_ peer: XPCChannel, to service: XPCActorService<Root>) async throws
  /// Routing is registered; this channel's dispatch opens after this returns.
  func peerDidBind(_ peer: XPCChannel, to service: XPCActorService<Root>) async
  /// Admission succeeded but preparation/registration failed. The peer is closed.
  /// Explicit bindings submitted after cooperative shutdown can still report
  /// rejection; they do not reopen its pipeline. Bare cancellation suppresses hooks.
  func peerDidFailToBind(
    _ peer: XPCChannel, to service: XPCActorService<Root>, error: any Error) async
  /// A registered peer ended, after its binding hook has finished. Runs once.
  func peerDidEnd(_ peer: XPCChannel, in service: XPCActorService<Root>) async
  /// Reception and dispatch stopped; peer hooks finished, registry still exists.
  /// Throwing reports cleanup failure but never prevents framework teardown.
  func serviceWillShutdown(_ service: XPCActorService<Root>) async throws
  /// Registry cleanup finished. Error is the will-shutdown hook's error, if any.
  /// Shutdown waiters and hosted process exit follow completion of this hook.
  func serviceDidShutdown(_ service: XPCActorService<Root>, error: (any Error)?) async
}

extension XPCActorServiceDelegate {
  public func serviceWillStart(_ service: XPCActorService<Root>) async throws {}
  public func serviceDidStart(_ service: XPCActorService<Root>) async {}
  public func peerWillBind(_ peer: XPCChannel, to service: XPCActorService<Root>) async throws {}
  public func peerDidBind(_ peer: XPCChannel, to service: XPCActorService<Root>) async {}
  public func peerDidFailToBind(
    _ peer: XPCChannel, to service: XPCActorService<Root>, error: any Error
  ) async {}
  public func peerDidEnd(_ peer: XPCChannel, in service: XPCActorService<Root>) async {}
  public func serviceWillShutdown(_ service: XPCActorService<Root>) async throws {}
  public func serviceDidShutdown(_ service: XPCActorService<Root>, error: (any Error)?) async {}
}

/// C-native admission, separate from asynchronous actor preparation.
/// Connections are inactive during audit; native peer requirements belong here.
/// A concrete conformer can carry `@main`: the default main constructs it with
/// `init()` and hosts its bundled XPC service on the OS main thread. Inject
/// production dependencies in that initializer; additional initializers may
/// configure embedded instances. A type implementing both native protocols
/// must implement main itself to select its process backend.
public protocol XPCConnectionActorServiceDelegate<Root>: XPCActorServiceDelegate {
  /// Constructs the production delegate used by the default process entry.
  init()
  /// Hosts a bundled service on the OS main thread. Provided by the protocol.
  @MainActor static func main()
  /// Installed before audit. When non-nil, do not install a second requirement.
  var peerCodeSigningRequirement: String? { get }
  func shouldAcceptConnection(
    _ connection: XPCConnection, in service: XPCActorService<Root>
  ) throws -> Bool
  func didRejectConnection(
    _ connection: XPCConnection, in service: XPCActorService<Root>, error: (any Error)?)
}

extension XPCConnectionActorServiceDelegate {
  @MainActor public static func main() { xpcMain(delegate: Self()) }
  public var peerCodeSigningRequirement: String? { nil }
  public func shouldAcceptConnection(
    _ connection: XPCConnection, in service: XPCActorService<Root>
  ) throws -> Bool { true }
  public func didRejectConnection(
    _ connection: XPCConnection, in service: XPCActorService<Root>, error: (any Error)?
  ) {}
}

/// Session-native admission. The request is borrowed for this synchronous
/// callback: do not retain it, cross an asynchronous boundary, or accept/reject
/// it yourself. Asynchronous authorization belongs in `peerWillBind`.
/// A concrete conformer can carry `@main`: the default main constructs it with
/// `init()` and hosts `serviceName` on the OS main thread. The launchd job must
/// advertise that exact name in MachServices; embedded listeners receive their
/// names explicitly and do not consult this process-entry property.
public protocol XPCSessionActorServiceDelegate<Root>: XPCActorServiceDelegate {
  /// Constructs the production delegate used by the default process entry.
  init()
  /// The MachServices name advertised by this process's launchd job.
  @MainActor static var serviceName: String { get }
  /// Hosts that named service on the OS main thread. Provided by the protocol.
  @MainActor static func main()
  func shouldAcceptSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<Root>
  ) throws -> Bool
  func didRejectSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<Root>,
    error: (any Error)?)
}

extension XPCSessionActorServiceDelegate {
  @MainActor public static func main() {
    xpcSessionMain(service: serviceName, delegate: Self())
  }
  public func shouldAcceptSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<Root>
  ) throws -> Bool { true }
  public func didRejectSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<Root>,
    error: (any Error)?
  ) {}
}
