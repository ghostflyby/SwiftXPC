// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing
@testable import DistributedXPC

@XPCService
distributed actor DelegateRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "delegate"
  }
}

struct XPCServiceDelegateTests {
  private final class CountingDelegate: XPCServiceDelegate {
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

  @Test func HostedShutdownCompletionRunsAfterServiceWillShutdown() async throws {
    let events = Mutex<[String]>([])
    let service = try xpcTest(
      DelegateRoot.self,
      XPCServiceConfiguration(onShutdown: { events.withLock { $0.append("shutdown") } }))
    defer { service.close() }

    // The completion is the hosting layer's process exit: installed by
    // xpcMain, it must run after the delegate hook, exactly once, on the
    // shutdown-driving thread.
    service.host.setShutdownCompletion { events.withLock { $0.append("exit") } }
    service.host.requestShutdown()
    service.host.requestShutdown()

    // requestShutdown is synchronous: hook and completion have both run by
    // the time it returns.
    #expect(events.withLock { $0 } == ["shutdown", "exit"])
  }

  @Test func PlainHostAcceptsPeerMessageWithoutCrashing() async throws {
    // Regression: a bare XPCServiceHost (default no-op peer handler) used to
    // activate peers with no libxpc event handler installed — the first
    // incoming message raised _xpc_api_misuse and killed the process. The
    // fallback handler must keep the service alive and silent instead.
    let host = XPCServiceHost(XPCServiceConfiguration())
    let listener = XPCConnection(name: nil)
    listener.setEventHandler { object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      host.accept(XPCConnection(xpc_object: object.xpc_object))
    }
    listener.activate()
    let client = try XPCConnection.unmarshal(from: listener.marshal())
    client.setEventHandler { _ in }
    client.activate()

    client.sendAndForget(message: XPCDictionary())
    host.requestShutdown()  // Reaching this point proves the process survived.
    listener.cancel()
  }

  @Test func DefaultHostingServesSingletonRoot() async throws {
    let channel = try RootChannel(DelegateRoot.self)
    defer { channel.close() }
    let root = try DelegateRoot.connect(using: channel.client)
    #expect(try await root.ping() == "delegate")
  }

  @Test func RawConformerHooksDriveTheServer() async throws {
    let delegate = CountingDelegate()
    let channel = try RootChannel(DelegateRoot.self, delegate)
    defer { channel.close() }
    let root = try DelegateRoot.connect(using: channel.client)
    #expect(try await root.ping() == "delegate")
    #expect(delegate.audits.withLock { $0 } == 1)
    #expect(delegate.accepted.withLock { $0 } == 1)
  }

  @Test func EventLogRecordsHookSequenceAndShutdown() async throws {
    let log = XPCServiceEventLog()
    let service = try xpcTest(DelegateRoot.self, XPCServiceConfiguration(), eventLog: log)
    defer { service.close() }

    #expect(try await service.client.root.ping() == "delegate")
    #expect(log.events.map(\.kind) == [.shouldAcceptPeer, .didAcceptPeer])

    service.host.requestShutdown()
    // The cancelled peer's peerDidEnd races serviceWillShutdown (different
    // threads), so assert the prefix and the shutdown event separately.
    #expect(log.events.map(\.kind).prefix(2) == [.shouldAcceptPeer, .didAcceptPeer])
    #expect(log.events.map(\.kind).contains(.serviceWillShutdown))
  }

  @Test func WatchdogForceClosesTheServiceAfterDuration() async throws {
    let service = try xpcTest(DelegateRoot.self, watchdog: .milliseconds(50))
    #expect(try await service.client.root.ping() == "delegate")

    // The watchdog closes the coordinator so a hung test fails fast:
    // pending calls observe the channel going down.
    await service.waitUntilClosed()
    await #expect(throws: XPCConnection.ConnectionError.self) {
      _ = try await service.client.root.ping()
    }
  }

  @Test func XPCRootTestCoordinatorResolvesRootAndReportsShutdown() async throws {
    let shutdowns = Mutex<Int>(0)
    let service = try xpcTest(
      DelegateRoot.self,
      XPCServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } }))
    defer { service.close() }

    // The client side is a production channel: root resolved at construction.
    #expect(try await service.client.root.ping() == "delegate")

    // A cooperative shutdown on the exposed server never exits the process;
    // it only tears the sessions down and fires the hook exactly once.
    service.host.requestShutdown()
    #expect(await service.host.expectShutdown(timeout: .seconds(2)))
    #expect(shutdowns.withLock { $0 } == 1)
  }

  @Test func ExpectCountHoldsThresholdUntilReached() async throws {
    let log = XPCServiceEventLog()
    log.append(.didAcceptPeer)  // count = 1: below the threshold.

    // Below the threshold the waiter must not resolve early — it expires.
    async let pending = log.expectCount(
      .didAcceptPeer, atLeast: 2, timeout: .milliseconds(150))
    #expect(await pending == false)

    // Reaching the threshold resolves the same expectation.
    async let satisfied = log.expectCount(
      .didAcceptPeer, atLeast: 2, timeout: .seconds(2))
    log.append(.didAcceptPeer)
    #expect(await satisfied)
  }

  @Test func XPCRootTestCoordinatorDropServerPeerEmitsDisconnectAndReestablishes() async throws {
    let log = XPCServiceEventLog()
    let service = try xpcTest(DelegateRoot.self, XPCServiceConfiguration(), eventLog: log)
    defer { service.close() }
    #expect(try await service.client.root.ping() == "delegate")

    // Drop surfaces on the production event stream...
    service.dropServerPeer()
    // The drop surfaces deterministically in the hook log...
    #expect(await log.expectEvent(.peerDidEnd, timeout: .seconds(2)) != nil)

    // ...and the next call provokes libxpc to re-dial the coordinator's
    // listener endpoint: a call racing the teardown may observe .interrupted
    // once, so retry until the fresh session answers (a second
    // didAcceptPeer) and the same root proxy keeps working.
    #expect(
      try await service.client.retrying(
        XPCRetryPolicy(
          maxAttempts: 5, initialBackoff: .milliseconds(20), multiplier: 1,
          maxBackoff: .milliseconds(100))
      ) { _ in
        try await service.client.root.ping()
      } == "delegate")
    #expect(await log.expectCount(.didAcceptPeer, atLeast: 2, timeout: .seconds(2)))
  }

  @Test func CoordinatorExpectShutdownResolvesFalseAfterCancel() async throws {
    let service = try xpcTest(
      DelegateRoot.self,
      XPCServiceConfiguration(),
      eventLog: XPCServiceEventLog())
    defer { service.close() }

    // The waiter suspends; cancel() must release it with `false` — a
    // cancelled host never runs the pipeline.
    let waiter = Task { await service.waitForShutdown(timeout: .seconds(2)) }
    service.host.cancel()

    #expect(await waiter.value == false)
    #expect(await !service.host.expectShutdown(timeout: .milliseconds(100)))
  }

  @Test func XPCRootTestCoordinatorRetryingRidesOutServerPeerDrop() async throws {
    let log = XPCServiceEventLog()
    let service = try xpcTest(
      DelegateRoot.self,
      XPCServiceConfiguration(),
      eventLog: log)
    defer { service.close() }
    #expect(
      try await service.client.retrying(XPCRetryPolicy.once) { _ in
        try await service.client.root.ping()
      } == "delegate")

    async let peerDidEnd = log.expectEvent(.peerDidEnd, timeout: .seconds(2))
    async let acceptedAgain = log.expectCount(.didAcceptPeer, atLeast: 2, timeout: .seconds(2))

    service.dropServerPeer()

    // `retrying` is client-side logic, so it runs unchanged in-process: the
    // interrupted call is retried, the channel re-dials the anonymous
    // listener, and the fresh session answers the same call.
    #expect(
      try await service.client.retrying(
        XPCRetryPolicy(
          maxAttempts: 3, initialBackoff: .milliseconds(10), multiplier: 1,
          maxBackoff: .milliseconds(50))
      ) { _ in
        try await service.client.root.ping()
      } == "delegate")

    #expect(await peerDidEnd != nil)
    #expect(await acceptedAgain)
  }

}
