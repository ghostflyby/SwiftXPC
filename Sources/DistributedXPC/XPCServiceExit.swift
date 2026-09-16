// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed

/// Opt-in semantics for a hosted root actor: the root is a process-wide
/// singleton, and the service exits cooperatively when fully disconnected.
///
/// Conforming roots are hosted on the library-owned long-lived system
/// (`XPCDistributedActorSystem.serviceHost`): every accepted peer connection
/// is bound to `shared`, so all clients share one root instance — and its
/// serial executor. Throughput work belongs in child actors, which still run
/// concurrently.
///
/// When the last accepted session disconnects and no exported child channel
/// has live peers, the server runs the cooperative shutdown pipeline
/// (`serviceWillShutdown`, then `exit(0)` under hosted `xpcMain`'s default
/// `exitOnShutdown: true`). The check arms with the first connection, so a
/// service that has never seen a client never exits — launchd on-demand cold
/// starts are safe. Clients observe the shutdown as their channels going
/// down; a named-service root transparently relaunches on its next call.
///
/// Child actors the singleton creates are hosted on the same system. When
/// every export session minted for a child has drained (zero live peers, and
/// none of them an un-dialed in-flight wire), the registry stops pinning it:
/// an unreferenced child is released, while children the singleton itself
/// still references stay alive and are re-adopted on their next export. The
/// singleton's own registry entry is never reclaimed. A wire that is handed
/// out but never dialed keeps the service (and the child) alive
/// indefinitely — a receiver that drops a reference without dialing is
/// indistinguishable from a slow one.
@available(macOS 15, *)
public protocol XPCServiceExit: XPCRootActor {
  /// The process-wide singleton root. Declare `shared` as a computed
  /// property over a file-scoped constant — a `static let` stored on the
  /// actor itself cannot call the isolated `init(actorSystem:)` under Swift
  /// 6 strict concurrency:
  ///
  ///     private let sharedRoot = MyRoot(actorSystem: .serviceHost)
  ///     extension MyRoot: XPCServiceExit {
  ///       static var shared: MyRoot { sharedRoot }
  ///     }
  ///
  /// Materializing `shared` before the first connection is safe: the host
  /// system reserves `.root` at creation, so the singleton keeps that
  /// identity regardless of creation order.
  ///
  /// Every accepted peer connection is bound to this instance; its methods
  /// run serialized on its executor regardless of which client called them.
  ///
  /// One hosted server and one `XPCServiceExit` root type per process: the
  /// handlers that route cooperative shutdown requests and idle-exit
  /// accounting live on the process-global service host system and are
  /// overwritten by each accepted connection.
  static var shared: Self { get }
}
