// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import SwiftXPC

/// The bootstrap actor type constructed once per actor service.
/// All accepted channels on that service bind to the same root instance.
public protocol XPCRootActor: XPCExportableActor,
  XPCDistributedTargetMetadataProviding
{
  init(actorSystem: XPCDistributedActorSystem)
}

/// The SwiftUI-`App`-style entry point: a type carrying both the service's
/// root actor and its delegate customization, marked `@main` directly.
///
///     @main
///     struct AgentService: XPCApp {
///       typealias Root = ServiceRoot
///
///       var peerCodeSigningRequirement: String? { "identifier \"com.example.agent\"" }
///       func shouldAcceptPeer(_ connection: XPCChannel) throws -> Bool {
///         connection.euid == 501
///       }
///     }
///
/// The type must be constructible with no arguments: the library-provided
/// `main()` hosts a fresh instance as the delegate of an `XPCServiceHost`
/// serving one root per service, and exits the process after a cooperative
/// shutdown. All customization lives in the conformer's own requirement
/// implementations, exactly as in `xpcMain`.
public protocol XPCApp: XPCServiceDelegate {
  /// The root actor type constructed by the app.
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
/// one `rootType` instance on every accepted peer connection. Never returns.
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
/// standalone `XPCActorService(rootType, delegate)`, neither of which ever
/// exits the process.
@MainActor
public func xpcMain<Root>(
  _ rootType: Root.Type,
  _ delegate: any XPCServiceDelegate = XPCServiceConfiguration()
) -> Never where Root: XPCRootActor {
  let service = XPCActorService(rootType, delegate)
  let server = service.host
  // The hosted service *is* the process: retire it right after the
  // delegate's shutdown hook has run.
  server.setShutdownCompletion {
    service.cancel(); exit(0)
  }
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
    transport: XPCChannelTransport = .cConnection,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try XPCRootConnection<Self>.connect(
      toService: serviceName,
      transport: transport,
      peerCodeSigningRequirement: peerCodeSigningRequirement
    ).root
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
    using channel: XPCChannel,
    peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try XPCRootConnection<Self>.connect(
      using: channel,
      peerCodeSigningRequirement: peerCodeSigningRequirement
    ).root
  }
}
