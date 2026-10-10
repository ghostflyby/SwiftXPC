// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
@testable import DistributedXPC
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@XPCService
distributed actor StatefulServiceRoot: TestRoot {
  typealias ActorSystem = XPCDistributedActorSystem

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

  distributed func me() -> StatefulServiceRoot {
    self
  }

  /// Returns the same child instance on every call after the first: proves
  /// that children the service root itself references survive child reclamation.
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

/// All clients of one actor service share its root and child registry.
@Suite(.serialized)
struct XPCActorServiceTests {
  @Test func ServicesOwnIndependentRootsAndRegistries() async throws {
    let first = try await ActorServiceChannel(StatefulServiceRoot.self)
    let second = try await ActorServiceChannel(StatefulServiceRoot.self)
    defer { first.close(); second.close() }
    #expect(first.service.root !== second.service.root)
    #expect(first.service.root.id == .root)
    #expect(second.service.root.id == .root)
    #expect(first.service.root.actorSystem.connection == nil)
    let a = try StatefulServiceRoot.connect(using: first.client)
    let b = try StatefulServiceRoot.connect(using: second.client)
    #expect(try await a.bump() == 1)
    #expect(try await a.bump() == 2)
    #expect(try await b.bump() == 1)
  }

  @Test func RootFactoryRejectsForeignActorSystem() async {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      let foreign = XPCDistributedActorSystem()
      foreign.reserveRootID()
      let root = StatefulServiceRoot(actorSystem: foreign)
      _ = try await XPCActorService(TestActorDelegate<StatefulServiceRoot>(factory: { _ in root }))
    }
    let output = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    #expect(
      output.contains("The root factory must construct the first actor on the supplied system"))
  }

  @Test func RootFactoryRejectsUnregisteredProxy() async {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      _ = try await XPCActorService(
        TestActorDelegate<StatefulServiceRoot>(factory: { system in
          try StatefulServiceRoot.resolve(id: .root, using: system)
        }))
    }
    let output = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    #expect(
      output.contains("The root factory must construct the first actor on the supplied system"))
  }

  private func hostRegistryContains(_ id: XPCActorID, in system: XPCDistributedActorSystem) -> Bool
  {
    if id == .root {
      return (try? system.resolve(id: id, as: StatefulServiceRoot.self)) != nil
    }
    return (try? system.resolve(id: id, as: ExitWorker.self)) != nil
  }

  @Test func DrainWaiterResumesWhenSystemIsInvalidated() async throws {
    // invalidate() removes export sessions without going through the
    // normal drain notification; a pending waitForExportDrain must still be
    // released, or it would hang forever (the wait has no timeout).
    let system = XPCDistributedActorSystem()
    let worker = ExitWorker(actorSystem: system)
    _ = try system.export(worker)  // Minted but never dialed: a live session.
    #expect(system.hasLiveExportPeers)

    // The registration callback fires only after the continuation is stored.
    let registered = DispatchSemaphore(value: 0)
    let resumed = DispatchSemaphore(value: 0)
    let waiter = Task {
      await system.waitForExportDrain(onRegistered: { registered.signal() })
      resumed.signal()
    }
    #expect(await waitForTestSignal(registered))
    system.invalidate()
    #expect(!system.hasLiveExportPeers)
    #expect(await waitForTestSignal(resumed))
    _ = waiter
  }

  @Test func ServiceRootServesAllPeersThroughOneInstance() async throws {
    let channel = try await ActorServiceChannel(StatefulServiceRoot.self)
    defer { channel.close() }

    let first = try StatefulServiceRoot.connect(using: channel.client)
    // Repeated calls share the service root.
    let after = try await first.bump()
    #expect(try await first.bump() == after + 1)

    let secondClient = try channel.makeClient()
    let second = try StatefulServiceRoot.connect(using: secondClient)
    // A second call landing on the same service root instance continues the
    // counter; per-session roots would have started over.
    #expect(try await second.bump() == after + 2)
  }

  @Test func ServiceChildActorsDoNotCollideWithRoot() async throws {
    let channel = try await ActorServiceChannel(StatefulServiceRoot.self)
    defer { channel.close() }

    let first = try StatefulServiceRoot.connect(using: channel.client)
    let firstAfter = try await first.bump()
    #expect(try await first.bump() == firstAfter + 1)

    // Accepting another peer must not consume a second root identity.
    let secondClient = try channel.makeClient()
    let second = try StatefulServiceRoot.connect(using: secondClient)
    let secondAfter = try await second.bump()
    #expect(try await second.bump() == secondAfter + 1)

    let worker = try await first.makeWorker()
    #expect(worker.id != .root)
    #expect(try await worker.greet() == "worker")
  }

  @Test func ChildSurvivesRootClientDisconnect() async throws {
    // Service ownership contract: the root (and children it minted on the service
    // host) outlive any one client connection — retirement is launchd's or
    // an explicit requestShutdown's, never a disconnect's.
    let channel = try await ActorServiceChannel(StatefulServiceRoot.self)
    defer { channel.close() }
    let root = try StatefulServiceRoot.connect(using: channel.client)
    let worker = try await root.makeWorker()
    _ = try await worker.greet()
    let before = try await root.bump()

    channel.client.cancel()
    await channel.client.waitForDisconnection()
    #expect(try await worker.greet() == "worker")

    // A fresh client reaches the same service root — the counter continues —
    // and its previously minted child is still reachable through it.
    let freshClient = try channel.makeClient()
    let fresh = try StatefulServiceRoot.connect(using: freshClient)
    #expect(try await fresh.bump() == before + 1)
    #expect(try await worker.greet() == "worker")
  }

  @Test func FullyDrainedChildIsUnpinned() async throws {
    let channel = try await ActorServiceChannel(StatefulServiceRoot.self)
    defer { channel.close() }
    let root = try StatefulServiceRoot.connect(using: channel.client)
    let host = channel.service.root.actorSystem

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
    #expect(!hostRegistryContains(id, in: host))
  }

  @Test func ReadoptedChildIsReexportable() async throws {
    let channel = try await ActorServiceChannel(StatefulServiceRoot.self)
    defer { channel.close() }
    let root = try StatefulServiceRoot.connect(using: channel.client)
    let host = channel.service.root.actorSystem

    var worker: ExitWorker? = try await root.makeOrReuseWorker()
    #expect(try await worker?.bump() == 1)
    worker = nil
    await host.waitForExportDrain()

    // The drained child's registry pin was released, but the service root still
    // references it: re-handing it out must re-adopt the registry entry and
    // serve the same living instance.
    let reacquired = try await root.makeOrReuseWorker()
    // A successful call on the reacquired proxy proves the re-export went
    // through, which re-adopts the registry entry.
    #expect(try await reacquired.bump() == 2)
    #expect(hostRegistryContains(reacquired.id, in: host))
  }

  @Test func RootRegistryEntrySurvivesSelfHandout() async throws {
    let channel = try await ActorServiceChannel(StatefulServiceRoot.self)
    defer { channel.close() }
    let root = try StatefulServiceRoot.connect(using: channel.client)
    let host = channel.service.root.actorSystem

    var handedOut: StatefulServiceRoot? = try await root.me()
    _ = try await handedOut?.bump()
    #expect(host.hasLiveExportPeers)

    handedOut = nil
    await host.waitForExportDrain()

    // The `.root` registry entry is never reclaimed...
    #expect(hostRegistryContains(.root, in: host))
    // ...and a fresh connection still reaches the service root.
    let freshClient = try channel.makeClient()
    let fresh = try StatefulServiceRoot.connect(using: freshClient)
    _ = try await fresh.bump()
  }
}
