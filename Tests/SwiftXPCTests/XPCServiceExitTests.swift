// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@available(macOS 15, *)
@XPCService
distributed actor ExitSingletonRoot: XPCRootActor, XPCServiceExit {
  typealias ActorSystem = XPCDistributedActorSystem

  // The witness reads the file-scoped singleton; creation itself lives at
  // file scope because the witness requirement's isolation inference breaks
  // when the type creates itself in its own static scope (Swift 6.4).
  // NOTE: placed first in the file on purpose — as a P0 detector this test
  // only works when it runs before any accept materializes the singleton.
  static var shared: ExitSingletonRoot { singletonInstance }

  private let bumps = Mutex(0)
  private let cachedWorker = Mutex<ExitWorker?>(nil)

  distributed func bump() -> Int {
    bumps.withLock {
      $0 += 1; return $0
    }
  }

  distributed func makeWorker() -> ExitWorker {
    ExitWorker(actorSystem: actorSystem)
  }

  distributed func me() -> ExitSingletonRoot {
    self
  }

  /// Returns the same child instance on every call after the first: proves
  /// that children the singleton itself references survive child reclamation.
  distributed func makeOrReuseWorker() -> ExitWorker {
    if let cached = cachedWorker.withLock({ $0 }) { return cached }
    let worker = ExitWorker(actorSystem: actorSystem)
    cachedWorker.withLock { $0 = worker }
    return worker
  }

  distributed func hasCachedWorker() -> Bool {
    cachedWorker.withLock { $0 != nil }
  }
}

@available(macOS 15, *)
private let singletonInstance = ExitSingletonRoot(actorSystem: .serviceHost)

@available(macOS 15, *)
@XPCService
distributed actor ExitWorker {
  typealias ActorSystem = XPCDistributedActorSystem

  private let bumps = Mutex(0)

  distributed func greet() -> String { "worker" }

  distributed func bump() -> Int {
    bumps.withLock {
      $0 += 1; return $0
    }
  }
}

/// The service-host system is process-global, so tests exercising the
/// singleton path (and the handlers installed on it) run serialized.
@Suite(.serialized)
struct XPCServiceExitTests {
  @available(macOS 15, *)
  @Test func EagerlyMaterializedSingletonKeepsRootIdentity() async throws {
    // P0 repro: materializing `shared` before the first connection used to
    // consume a regular identity (ID 1); clients dialing `.root` then failed
    // with an opaque error and the reservation was consumed by the next child.
    _ = ExitSingletonRoot.shared
    #expect(hostRegistryContains(.root))

    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let after = try await root.bump()
    #expect(try await root.bump() == after + 1)

    let worker = try await root.makeWorker()
    #expect(worker.id != .root)
    _ = try await worker.greet()
  }

  @available(macOS 15, *)
  private func hostRegistryContains(_ id: XPCActorID) -> Bool {
    XPCDistributedActorSystem.serviceHost.activeActorsLock.withLock { $0[id] != nil }
  }

  @available(macOS 15, *)
  @Test func SingletonRootServesAllPeersThroughOneInstance() async throws {
    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }

    let first = try ExitSingletonRoot.connect(using: channel.client)
    // The singleton is process-global: assert the bump advanced by one
    // rather than pinning the absolute value.
    let after = try await first.bump()
    #expect(try await first.bump() == after + 1)

    let secondClient = try XPCConnection.unmarshal(from: channel.listener.marshal())
    let second = try ExitSingletonRoot.connect(using: secondClient)
    // A second call landing on the same singleton instance continues the
    // counter; per-session roots would have started over.
    #expect(try await second.bump() == after + 2)
  }

  @available(macOS 15, *)
  @Test func IdleExitFiresWhenFullyDisconnected() async throws {
    let shutdowns = Mutex(0)
    let channel = try RootChannel(
      ExitSingletonRoot.self,
      XPCServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } })
    )
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    // The singleton is process-global: assert the bump advanced by one
    // rather than pinning the absolute value.
    let before = try await root.bump()
    #expect(try await root.bump() == before + 1)

    channel.client.cancel()

    #expect(await pollUntil { shutdowns.withLock { $0 } == 1 })
    // The retired service refuses new peers.
    let lateClient = try XPCConnection.unmarshal(from: channel.listener.marshal())
    let lateRoot = try ExitSingletonRoot.connect(using: lateClient)
    await #expect(throws: XPCConnection.ConnectionError.interrupted) {
      _ = try await lateRoot.bump()
    }
  }

  @available(macOS 15, *)
  @Test func SingletonChildActorsDoNotCollideWithRoot() async throws {
    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }

    let first = try ExitSingletonRoot.connect(using: channel.client)
    let firstAfter = try await first.bump()
    #expect(try await first.bump() == firstAfter + 1)

    // A second accept arms a root-ID reservation on the host system; a child
    // created afterwards must not be hijacked onto `.root`.
    let secondClient = try XPCConnection.unmarshal(from: channel.listener.marshal())
    let second = try ExitSingletonRoot.connect(using: secondClient)
    let secondAfter = try await second.bump()
    #expect(try await second.bump() == secondAfter + 1)

    let worker = try await first.makeWorker()
    #expect(worker.id != .root)
    #expect(try await worker.greet() == "worker")
  }

  @available(macOS 15, *)
  @Test func LiveChildChannelBlocksIdleExit() async throws {
    let shutdowns = Mutex(0)
    let channel = try RootChannel(
      ExitSingletonRoot.self,
      XPCServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } })
    )
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let worker = try await root.makeWorker()
    _ = try await worker.greet()

    // The root session dies, but the exported child channel is still a live
    // remote reference: the service must stay up and the child reachable.
    channel.client.cancel()
    try await Task.sleep(for: .milliseconds(200))
    #expect(shutdowns.withLock { $0 } == 0)
    #expect(try await worker.greet() == "worker")

    // Last remote reference drops -> fully disconnected -> idle exit.
    worker.actorSystem.connection.cancel()
    #expect(await pollUntil { shutdowns.withLock { $0 } == 1 })
  }

  @available(macOS 15, *)
  @Test func FullyDrainedChildIsUnpinned() async throws {
    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let host = XPCDistributedActorSystem.serviceHost

    var worker: ExitWorker? = try await root.makeWorker()
    let workerID = worker?.id
    let id = try #require(workerID)
    _ = try await worker?.greet()
    #expect(await pollUntil { host.hasLiveExportPeers })

    worker = nil

    #expect(await pollUntil { !host.hasLiveExportPeers })
    #expect(await pollUntil { !hostRegistryContains(id) })
  }

  @available(macOS 15, *)
  @Test func ReadoptedChildIsReexportable() async throws {
    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let host = XPCDistributedActorSystem.serviceHost

    var worker: ExitWorker? = try await root.makeOrReuseWorker()
    #expect(try await worker?.bump() == 1)
    worker = nil
    #expect(await pollUntil { !host.hasLiveExportPeers })

    // The drained child's registry pin was released, but the singleton still
    // references it: re-handing it out must re-adopt the registry entry and
    // serve the same living instance.
    let reacquired = try await root.makeOrReuseWorker()
    #expect(try await reacquired.bump() == 2)
    #expect(await pollUntil { hostRegistryContains(reacquired.id) })
  }

  @available(macOS 15, *)
  @Test func RootRegistryEntrySurvivesSelfHandout() async throws {
    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let host = XPCDistributedActorSystem.serviceHost

    var handedOut: ExitSingletonRoot? = try await root.me()
    _ = try await handedOut?.bump()
    #expect(await pollUntil { host.hasLiveExportPeers })

    handedOut = nil
    #expect(await pollUntil { !host.hasLiveExportPeers })

    // The `.root` registry entry is never reclaimed...
    #expect(hostRegistryContains(.root))
    // ...and a fresh connection still reaches the singleton.
    let freshClient = try XPCConnection.unmarshal(from: channel.listener.marshal())
    let fresh = try ExitSingletonRoot.connect(using: freshClient)
    _ = try await fresh.bump()
  }

  @available(macOS 15, *)
  @Test func UndialedWireBlocksIdleExit() async throws {
    let shutdowns = Mutex(0)
    let channel = try RootChannel(
      ExitSingletonRoot.self,
      XPCServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } })
    )
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)

    // A handed-out-but-never-dialed export wire is an in-flight reference:
    // losing the root session must not retire the service out from under it.
    let worker = try await root.makeWorker()
    channel.client.cancel()
    try await Task.sleep(for: .milliseconds(200))
    #expect(shutdowns.withLock { $0 } == 0)

    // The wire survived; dialing it now works, and only its own drain
    // completes the idle exit.
    #expect(try await worker.greet() == "worker")
    worker.actorSystem.connection.cancel()
    #expect(await pollUntil { shutdowns.withLock { $0 } == 1 })
  }
}
