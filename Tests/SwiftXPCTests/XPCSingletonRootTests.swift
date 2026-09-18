// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@XPCService
distributed actor ExitSingletonRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  // The witness reads the file-scoped singleton; creation itself lives at
  // file scope because the witness requirement's isolation inference breaks
  // when the type creates itself in its own static scope (Swift 6.4).
  // This type intentionally overrides the default `shared`: it is the
  // stateful-singleton variant used to prove cross-peer instance identity.
  // (The old order-dependent P0 detector is structurally impossible now:
  // the service host reserves `.root` at creation, before any type can
  // materialize a shared instance.)
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

private let singletonInstance = ExitSingletonRoot(actorSystem: .serviceHost)

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
struct XPCSingletonRootTests {
  @Test func EagerlyMaterializedSingletonKeepsRootIdentity() async throws {
    // P0 repro: materializing `shared` before the first connection used to
    // consume a regular identity (ID 1); clients dialing `.root` then failed
    // with an opaque error and the reservation was consumed by the next child.
    _ = ExitSingletonRoot.shared
    #expect(hostRegistryContains(.root))

    let channel = try SharedSingletonChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let after = try await root.bump()
    #expect(try await root.bump() == after + 1)

    let worker = try await root.makeWorker()
    #expect(worker.id != .root)
    _ = try await worker.greet()
  }

  private func hostRegistryContains(_ id: XPCActorID) -> Bool {
    XPCDistributedActorSystem.serviceHost.activeActorsLock.withLock { $0[id] != nil }
  }

  @Test func SingletonRootServesAllPeersThroughOneInstance() async throws {
    let channel = try SharedSingletonChannel(ExitSingletonRoot.self)
    defer { channel.close() }

    let first = try ExitSingletonRoot.connect(using: channel.client)
    // The singleton is process-global: assert the bump advanced by one
    // rather than pinning the absolute value.
    let after = try await first.bump()
    #expect(try await first.bump() == after + 1)

    let secondClient = try channel.makeClient()
    let second = try ExitSingletonRoot.connect(using: secondClient)
    // A second call landing on the same singleton instance continues the
    // counter; per-session roots would have started over.
    #expect(try await second.bump() == after + 2)
  }

  @Test func SingletonChildActorsDoNotCollideWithRoot() async throws {
    let channel = try SharedSingletonChannel(ExitSingletonRoot.self)
    defer { channel.close() }

    let first = try ExitSingletonRoot.connect(using: channel.client)
    let firstAfter = try await first.bump()
    #expect(try await first.bump() == firstAfter + 1)

    // A second accept arms a root-ID reservation on the host system; a child
    // created afterwards must not be hijacked onto `.root`.
    let secondClient = try channel.makeClient()
    let second = try ExitSingletonRoot.connect(using: secondClient)
    let secondAfter = try await second.bump()
    #expect(try await second.bump() == secondAfter + 1)

    let worker = try await first.makeWorker()
    #expect(worker.id != .root)
    #expect(try await worker.greet() == "worker")
  }

  @Test func ChildSurvivesRootClientDisconnect() async throws {
    // Singleton contract: the root (and children it minted on the service
    // host) outlive any one client connection — retirement is launchd's or
    // an explicit requestShutdown's, never a disconnect's.
    let channel = try SharedSingletonChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let worker = try await root.makeWorker()
    _ = try await worker.greet()
    let before = try await root.bump()

    channel.client.cancel()
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await worker.greet() == "worker")

    // A fresh client reaches the same singleton — the counter continues —
    // and its previously minted child is still reachable through it.
    let freshClient = try channel.makeClient()
    let fresh = try ExitSingletonRoot.connect(using: freshClient)
    #expect(try await fresh.bump() == before + 1)
    #expect(try await worker.greet() == "worker")
  }

  @Test func FullyDrainedChildIsUnpinned() async throws {
    let channel = try SharedSingletonChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let host = XPCDistributedActorSystem.serviceHost

    var worker: ExitWorker? = try await root.makeWorker()
    let workerID = worker?.id
    let id = try #require(workerID)
    _ = try await worker?.greet()
    // A successful call proves the export channel is live.
    #expect(host.hasLiveExportPeers)

    worker = nil

    // Dropping the last remote reference drains the channel; the wait
    // resumes after child reclamation has been attempted.
    await host.waitForExportDrain()
    #expect(!host.hasLiveExportPeers)
    #expect(!hostRegistryContains(id))
  }

  @Test func ReadoptedChildIsReexportable() async throws {
    let channel = try SharedSingletonChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let host = XPCDistributedActorSystem.serviceHost

    var worker: ExitWorker? = try await root.makeOrReuseWorker()
    #expect(try await worker?.bump() == 1)
    worker = nil
    await host.waitForExportDrain()

    // The drained child's registry pin was released, but the singleton still
    // references it: re-handing it out must re-adopt the registry entry and
    // serve the same living instance.
    let reacquired = try await root.makeOrReuseWorker()
    // A successful call on the reacquired proxy proves the re-export went
    // through, which re-adopts the registry entry.
    #expect(try await reacquired.bump() == 2)
    #expect(hostRegistryContains(reacquired.id))
  }

  @Test func RootRegistryEntrySurvivesSelfHandout() async throws {
    let channel = try SharedSingletonChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)
    let host = XPCDistributedActorSystem.serviceHost

    var handedOut: ExitSingletonRoot? = try await root.me()
    _ = try await handedOut?.bump()
    #expect(host.hasLiveExportPeers)

    handedOut = nil
    await host.waitForExportDrain()

    // The `.root` registry entry is never reclaimed...
    #expect(hostRegistryContains(.root))
    // ...and a fresh connection still reaches the singleton.
    let freshClient = try channel.makeClient()
    let fresh = try ExitSingletonRoot.connect(using: freshClient)
    _ = try await fresh.bump()
  }
}
