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

  channel.host.requestShutdown()

  // Poll: the server-side cancel races with in-flight sends.
  let failed = await xpcPollUntil {
    (try? await root.ping()) == nil
  }
  #expect(failed)
}

@Test func ShutdownRejectsNewPeersThroughRejectHook() async throws {
  guard #available(macOS 15, *) else { return }
  let rejections = Mutex<Int>(0)
  let channel = try RootChannel(
    ShutdownRoot.self,
    XPCServiceConfiguration(
      onPeerReject: { _, error in
        // Shutdown-window rejections carry no error, like shouldAccept=false.
        if error == nil {
          rejections.withLock { $0 += 1 }
        }
      }
    )
  )
  defer { channel.close() }

  channel.host.requestShutdown()

  let lateClient = try channel.makeClient()
  let lateRoot = try ShutdownRoot.connect(using: lateClient)
  await #expect(throws: XPCConnection.ConnectionError.interrupted) {
    _ = try await lateRoot.ping()
  }
  #expect(await xpcPollUntil { rejections.withLock { $0 } == 1 })
}

@Test func ShutdownRejectsBeforeAuditWindow() async throws {
  guard #available(macOS 15, *) else { return }
  let audits = Mutex<Int>(0)
  let rejections = Mutex<Int>(0)
  let channel = try RootChannel(
    ShutdownRoot.self,
    XPCServiceConfiguration(
      shouldAccept: { _ in
        audits.withLock { $0 += 1 }
        return true
      },
      onPeerReject: { _, error in
        if error == nil {
          rejections.withLock { $0 += 1 }
        }
      }
    )
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")
  #expect(audits.withLock { $0 } == 1)

  channel.host.requestShutdown()

  let lateClient = try channel.makeClient()
  let lateRoot = try ShutdownRoot.connect(using: lateClient)
  await #expect(throws: XPCConnection.ConnectionError.interrupted) {
    _ = try await lateRoot.ping()
  }
  // The post-shutdown rejection happens before the audit window: the late
  // peer never reached `shouldAccept`.
  #expect(await xpcPollUntil { rejections.withLock { $0 } == 1 })
  #expect(audits.withLock { $0 } == 1)
}

@Test func ShutdownFiresOnShutdownExactlyOnce() async throws {
  guard #available(macOS 15, *) else { return }
  let shutdowns = Mutex<Int>(0)
  let channel = try RootChannel(
    ShutdownRoot.self,
    XPCServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } })
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)
  #expect(try await root.ping() == "root")

  channel.host.requestShutdown()
  channel.host.requestShutdown()
  channel.host.requestShutdown()

  #expect(await xpcPollUntil { shutdowns.withLock { $0 } == 1 })
  #expect(shutdowns.withLock { $0 } == 1)
}

@Test func RequestServiceShutdownBridgesFromRootActor() async throws {
  guard #available(macOS 15, *) else { return }
  let shutdowns = Mutex<Int>(0)
  let channel = try RootChannel(
    ShutdownRoot.self,
    XPCServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } })
  )
  defer { channel.close() }
  let root = try ShutdownRoot.connect(using: channel.client)

  // The reply to this very call is normally lost to the synchronous cancel;
  // fire it and observe the teardown instead of awaiting it.
  let reply = Task { try await root.shutdownService() }
  #expect(await xpcPollUntil { shutdowns.withLock { $0 } == 1 })

  let failed = await xpcPollUntil {
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
