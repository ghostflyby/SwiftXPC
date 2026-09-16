// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

/// Customization points for an `XPCRootActorServer`-hosted XPC service.
///
/// Every requirement has a default implementation, so a conformer — or the
/// bundled `XPCServiceConfiguration` — only states what it customizes:
///
///     struct AuditDelegate: XPCServiceDelegate {
///       typealias Root = ServiceRoot
///       var peerCodeSigningRequirement: String? { "identifier \"com.example.agent\"" }
///       func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool {
///         connection.euid == 501
///       }
///     }
///     // hosted entry point:
///     xpcMain(ServiceRoot.self, AuditDelegate())
///
/// The delegate is held strongly by the server and its methods are invoked
/// from arbitrary threads: peer hooks fire on XPC event queues (or the
/// accepting thread), `serviceWillShutdown` on whichever thread drove the
/// cooperative shutdown. Conformance therefore requires `Sendable`; keep
/// shared state inside the conformer behind a lock.
@available(macOS 15, *)
public protocol XPCServiceDelegate<Root>: Sendable {
  /// The root actor type served by the hosted service.
  associatedtype Root: XPCRootActor

  /// Kernel-enforced code signing requirement installed on every peer
  /// *before activation* (see `XPCConnection.setPeerCodeSigningRequirement`).
  /// Peers whose signature fails it are dropped by XPC; server-side the
  /// failure surfaces as a peer end. A requirement that cannot be installed
  /// (malformed string, unsupported platform) rejects the peer and reports
  /// the error to `didRejectPeer(_:error:)`: enforcement never silently
  /// degrades to none.
  var peerCodeSigningRequirement: String? { get }

  /// Audit window for each incoming peer connection, invoked after the
  /// requirement is installed and still *before activation* — inspect
  /// `connection.pid`/`connection.euid` here. Peers arriving after
  /// `requestShutdown()` are rejected before this hook runs. It may install
  /// a requirement via the `setPeer*Requirement` family, but a connection
  /// accepts at most one member of that family (libxpc traps on a second
  /// install), so when `peerCodeSigningRequirement` is set this hook must
  /// not install another. Returning `false` rejects the peer; throwing
  /// rejects the peer and reports the error to `didRejectPeer(_:error:)`.
  func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool

  /// Invoked once a peer is bound to a fresh root session (before
  /// activation). Useful for audit logging via `connection.pid`.
  func didAcceptPeer(_ connection: XPCConnection)

  /// Invoked when an accepted peer disconnects — including peers dropped by
  /// XPC for failing a code signing requirement at activation. The
  /// connection object is already invalid at this point; only identity
  /// inspection is meaningful.
  func peerDidEnd(_ connection: XPCConnection)

  /// Invoked when a peer is rejected before ever being accepted:
  /// `shouldAcceptPeer(_:)` returned `false` (error is `nil`), it threw, the
  /// code signing requirement could not be installed, or the server already
  /// shut down (error is `nil`). The connection is already cancelled; only
  /// identity inspection is meaningful.
  func didRejectPeer(_ connection: XPCConnection, error: (any Error)?)

  /// Invoked by the hosted `xpcMain(_:exitOnShutdown:)` entry point once the
  /// server exists, before the event loop starts — retain `server` here to
  /// reach `requestShutdown()` from outside the actor graph (e.g. a signal
  /// handler). Standalone `XPCRootActorServer` instances never fire it; the
  /// owner already holds the reference.
  func serviceWillStart(server: XPCRootActorServer<Root>)

  /// Invoked exactly once after a cooperative shutdown finished tearing
  /// every session down, on the thread that drove it. Under launchd's
  /// on-demand reaping, closing the last client connection is what retires
  /// the process, so `.xpc` services need nothing here; a long-lived agent
  /// that must exit explicitly can do so from this hook. Under hosted
  /// `xpcMain(_:exitOnShutdown:)` with the default `exitOnShutdown: true`,
  /// the process exits right after this hook returns.
  func serviceWillShutdown()

  /// Creates the per-session root actor served on an accepted peer.
  /// Only used for roots that are *not* `XPCServiceExit`: singleton roots
  /// are created by the root type itself (its `shared` property), so a
  /// customized `makeRoot` never runs there.
  func makeRoot(for system: XPCDistributedActorSystem) -> Root
}

@available(macOS 15, *)
extension XPCServiceDelegate {
  public var peerCodeSigningRequirement: String? { nil }

  public func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool { true }

  public func didAcceptPeer(_ connection: XPCConnection) {}

  public func peerDidEnd(_ connection: XPCConnection) {}

  public func didRejectPeer(_ connection: XPCConnection, error: (any Error)?) {}

  public func serviceWillStart(server: XPCRootActorServer<Root>) {}

  public func serviceWillShutdown() {}

  public func makeRoot(for system: XPCDistributedActorSystem) -> Root {
    Root(actorSystem: system)
  }
}

/// A closure-based `XPCServiceDelegate` whose fields all default to
/// "use the protocol default" (`nil` closures / `nil` requirement), so the
/// common service states only what it customizes:
///
///     xpcMain(ServiceRoot.self, XPCServiceConfiguration(
///       peerCodeSigningRequirement: "identifier \"com.example.agent\"",
///       shouldAccept: { $0.euid == 501 },
///       onPeerReject: { connection, error in log(connection, error) }))
///
/// Closure properties mirror the delegate methods they override; a `nil`
/// closure falls through to the `XPCServiceDelegate` default.
@available(macOS 15, *)
public struct XPCServiceConfiguration<Root: XPCRootActor>: XPCServiceDelegate {
  /// See `XPCServiceDelegate.peerCodeSigningRequirement`.
  public var peerCodeSigningRequirement: String?

  /// See `XPCServiceDelegate.shouldAcceptPeer(_:)`.
  public var shouldAccept: (@Sendable (XPCConnection) throws -> Bool)?

  /// See `XPCServiceDelegate.didAcceptPeer(_:)`.
  public var onPeerAccept: (@Sendable (XPCConnection) -> Void)?

  /// See `XPCServiceDelegate.peerDidEnd(_:)`.
  public var onPeerEnd: (@Sendable (XPCConnection) -> Void)?

  /// See `XPCServiceDelegate.didRejectPeer(_:error:)`.
  public var onPeerReject: (@Sendable (XPCConnection, (any Error)?) -> Void)?

  /// See `XPCServiceDelegate.serviceWillStart(server:)`.
  public var onStart: (@Sendable (XPCRootActorServer<Root>) -> Void)?

  /// See `XPCServiceDelegate.serviceWillShutdown()`.
  public var onShutdown: (@Sendable () -> Void)?

  /// See `XPCServiceDelegate.makeRoot(for:)`.
  public var rootFactory: (@Sendable (XPCDistributedActorSystem) -> Root)?

  /// - Parameters:
  ///   - peerCodeSigningRequirement: `nil` installs nothing.
  ///   - shouldAccept: `nil` accepts every peer.
  ///   - makeRoot: customizing this for an `XPCServiceExit` root is a
  ///     programming error and traps: singleton roots are created by the
  ///     root type itself, never per peer.
  public init(
    peerCodeSigningRequirement: String? = nil,
    shouldAccept: (@Sendable (XPCConnection) throws -> Bool)? = nil,
    onPeerAccept: (@Sendable (XPCConnection) -> Void)? = nil,
    onPeerEnd: (@Sendable (XPCConnection) -> Void)? = nil,
    onPeerReject: (@Sendable (XPCConnection, (any Error)?) -> Void)? = nil,
    onStart: (@Sendable (XPCRootActorServer<Root>) -> Void)? = nil,
    onShutdown: (@Sendable () -> Void)? = nil,
    makeRoot: (@Sendable (XPCDistributedActorSystem) -> Root)? = nil
  ) {
    if makeRoot != nil, Root.self is any XPCServiceExit.Type {
      preconditionFailure(
        "XPCServiceConfiguration.makeRoot is unsupported for XPCServiceExit roots:"
          + " the singleton is created by the root type's shared property,"
          + " per-peer construction never runs.")
    }
    self.peerCodeSigningRequirement = peerCodeSigningRequirement
    self.shouldAccept = shouldAccept
    self.onPeerAccept = onPeerAccept
    self.onPeerEnd = onPeerEnd
    self.onPeerReject = onPeerReject
    self.onStart = onStart
    self.onShutdown = onShutdown
    self.rootFactory = makeRoot
  }

  public func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool {
    guard let shouldAccept else { return true }
    return try shouldAccept(connection)
  }

  public func didAcceptPeer(_ connection: XPCConnection) {
    onPeerAccept?(connection)
  }

  public func peerDidEnd(_ connection: XPCConnection) {
    onPeerEnd?(connection)
  }

  public func didRejectPeer(_ connection: XPCConnection, error: (any Error)?) {
    onPeerReject?(connection, error)
  }

  public func serviceWillStart(server: XPCRootActorServer<Root>) {
    onStart?(server)
  }

  public func serviceWillShutdown() {
    onShutdown?()
  }

  public func makeRoot(for system: XPCDistributedActorSystem) -> Root {
    guard let rootFactory else { return Root(actorSystem: system) }
    return rootFactory(system)
  }
}
