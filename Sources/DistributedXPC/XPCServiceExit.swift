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
/// (`onShutdown`, then `exit(0)` under `distributedXPCMain`'s default
/// `exitOnShutdown: true`). The check arms with the first connection, so a
/// service that has never seen a client never exits — launchd on-demand cold
/// starts are safe. Clients observe the shutdown as their channels going
/// down; a named-service root transparently relaunches on its next call.
///
/// Child actors the singleton creates are hosted on the same system. When
/// every export session minted for a child has drained (zero live peers, and
/// none of them an un-dialed in-flight wire), the registry stops pinning it:
/// an unreferenced child is released, while children the root itself still
/// references stay alive. Note that a fully drained child loses its registry
/// entry, so it can no longer be re-exported — keep the registry entry by
/// holding the child only while it should stay reachable.
@available(macOS 15, *)
public protocol XPCServiceExit: XPCRootActor {
  /// The process-wide singleton root. Create it against the library-owned
  /// host system:
  ///
  ///     static let shared = MyRoot(actorSystem: .serviceHost)
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
