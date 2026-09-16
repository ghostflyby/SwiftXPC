// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing
@testable import DistributedXPC

@available(macOS 15, *)
@XPCService
distributed actor DelegateRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "delegate"
  }
}

struct XPCServiceDelegateTests {
  @available(macOS 15, *)
  private final class CountingDelegate: XPCServiceDelegate {
    typealias Root = DelegateRoot
    let audits = Mutex<Int>(0)
    let accepted = Mutex<Int>(0)

    func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool {
      audits.withLock { $0 += 1 }
      return true
    }

    func didAcceptPeer(_ connection: XPCConnection) {
      accepted.withLock { $0 += 1 }
    }
  }

  @available(macOS 15, *)
  private final class RecordingDelegate: XPCServiceDelegate {
    typealias Root = DelegateRoot
    let events = Mutex<[String]>([])

    var peerCodeSigningRequirement: String? { "req" }

    func shouldAcceptPeer(_ connection: XPCConnection) throws -> Bool {
      events.withLock { $0.append("shouldAccept") }
      return true
    }

    func serviceWillShutdown() {
      events.withLock { $0.append("shutdown") }
    }
  }

  @Test func CustomMakeRootConstructsPerSessionRoot() async throws {
    guard #available(macOS 15, *) else { return }
    let factoryCalls = Mutex<Int>(0)
    let channel = try RootChannel(
      DelegateRoot.self,
      XPCServiceConfiguration(
        makeRoot: { system in
          factoryCalls.withLock { $0 += 1 }
          return DelegateRoot(actorSystem: system)
        }))
    defer { channel.close() }
    let root = try DelegateRoot.connect(using: channel.client)
    #expect(try await root.ping() == "delegate")
    #expect(factoryCalls.withLock { $0 } == 1)
  }

  @Test func DefaultHostingServesRootWithoutFactory() async throws {
    guard #available(macOS 15, *) else { return }
    let channel = try RootChannel(DelegateRoot.self)
    defer { channel.close() }
    let root = try DelegateRoot.connect(using: channel.client)
    #expect(try await root.ping() == "delegate")
  }

  @Test func RawConformerHooksDriveTheServer() async throws {
    guard #available(macOS 15, *) else { return }
    let delegate = CountingDelegate()
    let channel = try RootChannel(DelegateRoot.self, delegate)
    defer { channel.close() }
    let root = try DelegateRoot.connect(using: channel.client)
    #expect(try await root.ping() == "delegate")
    #expect(delegate.audits.withLock { $0 } == 1)
    #expect(delegate.accepted.withLock { $0 } == 1)
  }

  @Test func ExitOnShutdownForwardsAndExitsAfterHook() throws {
    guard #available(macOS 15, *) else { return }
    let recorder = RecordingDelegate()
    let wrapper = ExitOnShutdown(
      base: recorder,
      exitProcess: { recorder.events.withLock { $0.append("exit") } })
    #expect(wrapper.peerCodeSigningRequirement == "req")
    #expect(try wrapper.shouldAcceptPeer(makeIdleConnection()))
    wrapper.serviceWillShutdown()
    // The injected exit must run after the wrapped hook, never before.
    #expect(recorder.events.withLock { $0 } == ["shouldAccept", "shutdown", "exit"])
  }

  @Test func XPCRootTestHarnessResolvesRootAndReportsShutdown() async throws {
    guard #available(macOS 15, *) else { return }
    let shutdowns = Mutex<Int>(0)
    let service = try xpcTest(
      DelegateRoot.self,
      XPCServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } }))
    defer { service.close() }

    // The client side is a production channel: root resolved at construction.
    #expect(try await service.channel.root.ping() == "delegate")

    // A cooperative shutdown on the exposed server never exits the process;
    // it only tears the sessions down and fires the hook exactly once.
    service.server.requestShutdown()
    #expect(await pollUntil { shutdowns.withLock { $0 } == 1 })
    #expect(shutdowns.withLock { $0 } == 1)
  }

  @Test func XPCRootTestHarnessDropServerPeerEmitsDisconnectAndReestablishes() async throws {
    guard #available(macOS 15, *) else { return }
    let service = try xpcTest(DelegateRoot.self)
    defer { service.close() }
    #expect(try await service.channel.root.ping() == "delegate")

    // Drop surfaces on the production event stream...
    let disconnected = Mutex(false)
    let collector = Task {
      for await event in service.channel.events {
        if case .disconnected = event {
          disconnected.withLock { $0 = true }
          break
        }
      }
    }
    service.dropServerPeer()
    #expect(await pollUntil { disconnected.withLock { $0 } })

    // ...and because the channel dials the harness's listener endpoint,
    // libxpc re-dials it and the server accepts a fresh session, so the
    // same root proxy keeps working.
    #expect(await pollUntil { (try? await service.channel.root.ping()) == "delegate" })
    collector.cancel()
  }

  @Test func XPCRootTestHarnessRetryingRidesOutServerPeerDrop() async throws {
    guard #available(macOS 15, *) else { return }
    let service = try xpcTest(DelegateRoot.self)
    defer { service.close() }
    #expect(
      try await service.channel.retrying(XPCRetryPolicy.once) { _ in
        try await service.channel.root.ping()
      } == "delegate")

    let disconnected = Mutex(false)
    let collector = Task {
      for await event in service.channel.events {
        if case .disconnected = event {
          disconnected.withLock { $0 = true }
          break
        }
      }
    }
    service.dropServerPeer()
    // The drop propagates asynchronously; wait until the channel is down.
    #expect(await pollUntil { disconnected.withLock { $0 } })

    // `retrying` is client-side logic, so it runs unchanged in-process: the
    // interrupted call is retried, the channel re-dials the anonymous
    // listener, and the fresh session answers the same call.
    #expect(
      try await service.channel.retrying(
        XPCRetryPolicy(
          maxAttempts: 3, initialBackoff: .milliseconds(10), multiplier: 1,
          maxBackoff: .milliseconds(50))
      ) { _ in
        try await service.channel.root.ping()
      } == "delegate")
    collector.cancel()
  }

  @Test func MakeRootConflictAppliesOnlyToExitRootsWithFactory() {
    guard #available(macOS 15, *) else { return }
    // Plain roots may customize makeRoot.
    #expect(
      XPCServiceConfiguration<DelegateRoot>.makeRootConflict(
        makeRoot: { system in DelegateRoot(actorSystem: system) }
      ) == nil)
    // Exit roots without a factory are fine; with one they conflict.
    #expect(
      XPCServiceConfiguration<ExitSingletonRoot>.makeRootConflict(makeRoot: nil) == nil)
    #expect(
      XPCServiceConfiguration<ExitSingletonRoot>.makeRootConflict(
        makeRoot: { _ in ExitSingletonRoot.shared }
      ) != nil)
  }
}
