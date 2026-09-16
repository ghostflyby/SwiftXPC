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

  @Test func MakeRootConflictAppliesOnlyToExitRootsWithFactory() {
    guard #available(macOS 15, *) else { return }
    // Plain roots may customize makeRoot.
    #expect(
      XPCServiceConfiguration<DelegateRoot>.makeRootConflict(
        rootType: DelegateRoot.self,
        makeRoot: { system in DelegateRoot(actorSystem: system) }
      ) == nil)
    // Exit roots without a factory are fine; with one they conflict.
    #expect(
      XPCServiceConfiguration<ExitSingletonRoot>.makeRootConflict(
        rootType: ExitSingletonRoot.self, makeRoot: nil) == nil)
    #expect(
      XPCServiceConfiguration<ExitSingletonRoot>.makeRootConflict(
        rootType: ExitSingletonRoot.self,
        makeRoot: { _ in ExitSingletonRoot.shared }
      ) != nil)
  }
}
