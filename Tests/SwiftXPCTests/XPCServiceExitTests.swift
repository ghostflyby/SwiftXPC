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
  private func hostRegistryContains(_ id: XPCActorID) -> Bool {
    XPCDistributedActorSystem.serviceHost.activeActorsLock.withLock { $0[id] != nil }
  }

  @available(macOS 15, *)
  @Test func SingletonRootServesAllPeersThroughOneInstance() async throws {
    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }

    let first = try ExitSingletonRoot.connect(using: channel.client)
    #expect(try await first.bump() == 1)

    let secondClient = try XPCConnection.unmarshal(from: channel.listener.marshal())
    let second = try ExitSingletonRoot.connect(using: secondClient)
    // A second call landing on the same singleton instance continues the
    // counter; per-session roots would have started from 1 again.
    #expect(try await second.bump() == 2)
  }

  @available(macOS 15, *)
  @Test func IdleExitFiresWhenFullyDisconnected() async throws {
    let shutdowns = Mutex(0)
    let channel = try RootChannel(
      ExitSingletonRoot.self,
      onShutdown: { shutdowns.withLock { $0 += 1 } }
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
      onShutdown: { shutdowns.withLock { $0 += 1 } }
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
  @Test func FullyDrainedChildIsNotReexportable() async throws {
    let channel = try RootChannel(ExitSingletonRoot.self)
    defer { channel.close() }
    let root = try ExitSingletonRoot.connect(using: channel.client)

    var worker: ExitWorker? = try await root.makeOrReuseWorker()
    #expect(try await worker?.bump() == 1)
    worker = nil
    #expect(await pollUntil { !XPCDistributedActorSystem.serviceHost.hasLiveExportPeers })

    // Documented edge: the drained child's registry entry was released, so
    // re-exporting it fails even though the singleton still references the
    // object. Services that re-hand-out children must keep the first export
    // channel alive instead.
    // makeOrReuseWorker is non-throwing, so the server-side export failure
    // surfaces as an opaque error.
    await #expect(throws: (any Error).self) {
      _ = try await root.makeOrReuseWorker()
    }
    #expect(try await root.hasCachedWorker())
  }
}
