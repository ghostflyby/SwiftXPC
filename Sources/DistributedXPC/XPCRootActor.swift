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
///       func shouldAcceptConnection(_ connection: XPCConnection) throws -> Bool {
///         connection.euid == 501
///       }
///     }
///
/// The type must be constructible with no arguments: the library-provided
/// `main()` hosts a fresh instance as the delegate of an `XPCServiceHost`
/// serving one root per service, and exits the process after a cooperative
/// shutdown. All customization lives in the conformer's own requirement
/// implementations, exactly as in `xpcMain`.
public protocol XPCApp: XPCConnectionServiceDelegate {
  /// The root actor type constructed by the app.
  associatedtype Root: XPCRootActor

  /// Creates the delegate for hosting.
  init()

  /// Hosted-process setup, before the event loop begins.
  @MainActor func serviceWillStart(host: XPCServiceHost)

  /// Runs the XPC service event loop with `Self` as the delegate. Never
  /// returns. Provided by the library; this is the `@main` entry point.
  @MainActor static func main()
}

extension XPCApp {
  @MainActor public func serviceWillStart(host: XPCServiceHost) {}
  @MainActor
  public static func main() {
    let app = Self()
    xpcMain(Self.Root.self, app, onStart: { app.serviceWillStart(host: $0) })
  }
}

/// Runs the XPC service event loop with default service behavior, serving
/// one `rootType` instance on every accepted peer connection. Never returns.
/// Must run on the main thread.
///
/// Equivalent to `xpcMain(rootType, XPCConnectionServiceConfiguration())`: peers are
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
  _ delegate: some XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
  onStart: @MainActor (XPCServiceHost) -> Void = { _ in }
) -> Never where Root: XPCRootActor {
  let service = XPCActorService(rootType, delegate, onShutdown: { exit(0) })
  let server = service.host
  onStart(server)
  return withExtendedLifetime(service) {
    SwiftXPC.xpcMain { connection in
      guard server.isAccepting else {
        rejectXPCConnection(connection, delegate: delegate, eventLog: nil, error: nil)
        return
      }
      guard admitXPCConnection(connection, delegate: delegate) else { return }
      server.bind(XPCChannel(connection))
    }
  }
}

extension XPCRootActor {
  /// Actor-only connection convenience. Use `XPCRootConnection` when lifecycle
  /// observation, explicit close, or retry policy is required.
  public static func connect(
    toService serviceName: String, transport: XPCChannelTransport = .cConnection
  ) throws -> Self {
    try XPCRootConnection<Self>.connect(toService: serviceName, transport: transport).root
  }

  public static func connect(using channel: XPCChannel) throws -> Self {
    try XPCRootConnection<Self>.connect(using: channel).root
  }

  /// Native C authentication, before activation and channel adoption.
  public static func connect(
    using connection: XPCConnection, peerCodeSigningRequirement: String? = nil
  ) throws -> Self {
    try XPCRootConnection<Self>.connect(
      using: connection, peerCodeSigningRequirement: peerCodeSigningRequirement
    ).root
  }
}
