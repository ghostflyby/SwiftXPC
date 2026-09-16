// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import Foundation
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@available(macOS 15, *)
@XPCService
distributed actor ShutdownRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "root"
  }

  /// Simulates a trusted client asking the service to retire itself. The
  /// shutdown cancels the session channel synchronously, so the reply to
  /// this very call is normally lost; clients should treat disconnection as
  /// the completion signal.
  distributed func shutdownService() {
    actorSystem.requestServiceShutdown()
  }
}

@Test func ShutdownTearsDownExistingSession() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ShutdownRoot.self)
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  channel.server.requestShutdown()

  // Poll: the server-side cancel races with in-flight sends.
  let failed = await pollUntil {
    (try? await root.ping()) == nil
  }
  #expect(failed)
}

@Test func ShutdownRejectsNewPeersThroughRejectHook() async throws {
  guard #available(macOS 15, *) else { return }
  let rejections = Mutex<Int>(0)
  let channel = try RootChannel(
    ShutdownRoot.self,
    onPeerReject: { _, error in
      // Shutdown-window rejections carry no error, like shouldAccept=false.
      if error == nil {
        rejections.withLock { $0 += 1 }
      }
    }
  )
  defer { channel.close() }

  channel.server.requestShutdown()

  let lateClient = try XPCConnection.unmarshal(from: channel.listener.marshal())
  let lateRoot = try ShutdownRoot.connect(using: lateClient)
  await #expect(throws: XPCConnection.ConnectionError.interrupted) {
    _ = try await lateRoot.ping()
  }
  #expect(await pollUntil { rejections.withLock { $0 } == 1 })
}

@Test func ShutdownFiresOnShutdownExactlyOnce() async throws {
  guard #available(macOS 15, *) else { return }
  let shutdowns = Mutex<Int>(0)
  let channel = try RootChannel(
    ShutdownRoot.self,
    onShutdown: { shutdowns.withLock { $0 += 1 } }
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  channel.server.requestShutdown()
  channel.server.requestShutdown()
  channel.server.requestShutdown()

  #expect(await pollUntil { shutdowns.withLock { $0 } == 1 })
  #expect(shutdowns.withLock { $0 } == 1)
}

@Test func RequestServiceShutdownBridgesFromRootActor() async throws {
  guard #available(macOS 15, *) else { return }
  let shutdowns = Mutex<Int>(0)
  let channel = try RootChannel(
    ShutdownRoot.self,
    onShutdown: { shutdowns.withLock { $0 += 1 } }
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)

  // The reply to this very call is normally lost to the synchronous cancel;
  // fire it and observe the teardown instead of awaiting it.
  let reply = Task { try await root.shutdownService() }
  #expect(await pollUntil { shutdowns.withLock { $0 } == 1 })

  let failed = await pollUntil {
    (try? await root.ping()) == nil
  }
  #expect(failed)
  _ = reply  // resolved by channel.close() cancelling the pending call
}

@Test func RequestServiceShutdownWithoutServerIsNoOp() async throws {
  guard #available(macOS 15, *) else { return }
  let system = XPCDistributedActorSystem(connection: makeIdleConnection())
  // Client-side systems host no server session: this must not route anywhere.
  system.requestServiceShutdown()
}

@Test func AwaitableShutdownWaitsForSessionTeardown() async throws {
  guard #available(macOS 15, *) else { return }
  let ended = Mutex(false)
  let finished = Mutex(false)
  let channel = try RootChannel(
    ShutdownRoot.self,
    onPeerEnd: { _ in
      ended.withLock { $0 = true }
      // Hold the invalidation chain open: leave() cannot run until this
      // returns, so a correct shutdown() must still be suspended.
      Thread.sleep(forTimeInterval: 0.2)
    }
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  let task = Task {
    await channel.server.shutdown()
    finished.withLock { $0 = true }
  }
  #expect(await pollUntil { ended.withLock { $0 } })
  // Still inside the held handler: the teardown has not completed yet.
  #expect(!finished.withLock { $0 })
  #expect(await pollUntil { finished.withLock { $0 } })
  _ = task
}

@Test func ShutdownAndWaitBlocksUntilTeardownCompletes() async throws {
  guard #available(macOS 15, *) else { return }
  let ended = Mutex(false)
  let channel = try RootChannel(
    ShutdownRoot.self,
    onPeerEnd: { _ in ended.withLock { $0 = true } }
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  // Detached to honor the blocking API's thread contract.
  try await Task.detached { channel.server.shutdownAndWait() }.value

  #expect(ended.withLock { $0 })
  // After a full teardown, a fresh awaitable call completes immediately.
  await channel.server.shutdown()
}

@Test func AwaitableShutdownWithoutSessionsReturnsImmediately() async throws {
  guard #available(macOS 15, *) else { return }
  let shutdowns = Mutex<Int>(0)
  let server = XPCRootActorServer<ShutdownRoot>(
    onShutdown: { shutdowns.withLock { $0 += 1 } }
  )

  await server.shutdown()
  #expect(shutdowns.withLock { $0 } == 1)
  server.shutdownAndWait()
  #expect(shutdowns.withLock { $0 } == 1)
}
