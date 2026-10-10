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
distributed actor DelegateRoot: TestRoot {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "delegate"
  }
}

/// One-shot async latch: `signal()` before `wait()` resolves the wait
/// immediately; otherwise `wait()` suspends until `signal()`.
private final class Latch: Sendable {
  private let state = Mutex<(fired: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

  func signal() {
    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.fired = true
      let waiter = state.waiter
      state.waiter = nil
      return waiter
    }
    waiter?.resume()
  }

  func wait() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      let alreadyFired = state.withLock { state -> Bool in
        if state.fired { return true }
        state.waiter = cont
        return false
      }
      if alreadyFired {
        cont.resume()
      }
    }
  }
}

struct XPCServiceDelegateTests {
  private final class CountingDelegate: XPCConnectionServiceDelegate {
    let audits = Mutex<Int>(0)
    let accepted = Mutex<Int>(0)

    func shouldAcceptConnection(_ peer: XPCConnection) throws -> Bool {
      audits.withLock { $0 += 1 }
      return true
    }

    func didAcceptPeer(_ peer: XPCChannel) {
      accepted.withLock { $0 += 1 }
    }
  }

  @Test func HostedShutdownCompletionRunsAfterServiceWillShutdown() async throws {
    let events = Mutex<[String]>([])
    let service = try await testService(
      DelegateRoot.self,
      XPCConnectionServiceConfiguration(onShutdown: { events.withLock { $0.append("shutdown") } }),
      onShutdown: { events.withLock { $0.append("exit") } })
    defer { service.close() }

    // The test adapter models the hosted process's completion: it runs
    // after the cleanup hook, exactly once, before shutdown waiters resume.
    service.service.host.requestShutdown()
    service.service.host.requestShutdown()

    #expect(await service.service.host.waitForShutdown(timeout: .seconds(2)))
    // Typed shutdown waits for the asynchronous hook and completion.
    #expect(events.withLock { $0 } == ["shutdown", "exit"])
  }

  @Test func PlainHostAcceptsPeerMessageWithoutCrashing() async throws {
    // Regression: a bare XPCServiceHost (default no-op peer handler) used to
    // activate peers with no libxpc event handler installed — the first
    // incoming message raised _xpc_api_misuse and killed the process. The
    // fallback handler must keep the service alive and silent instead.
    let host = XPCServiceHost(XPCConnectionServiceConfiguration())
    let listener = XPCConnection(name: nil)
    listener.setEventHandler { object in
      guard xpc_get_type(object) == XPC_TYPE_CONNECTION else { return }
      host.bind(XPCChannel(XPCConnection(xpc_object: object)))
    }
    listener.activate()
    let client = try XPCConnection.unmarshal(from: listener.marshal())
    client.setEventHandler { _ in }
    client.activate()

    client.sendAndForget(message: XPCDictionary())
    host.requestShutdown()  // Reaching this point proves the process survived.
    listener.cancel()
  }

  @Test func DefaultHostingServesServiceRoot() async throws {
    let channel = try await RootChannel(DelegateRoot.self)
    defer { channel.close() }
    let root = try DelegateRoot.connect(using: channel.client)
    #expect(try await root.ping() == "delegate")
  }

  @Test func CancelledHostRejectsNewPeersBeforeAudit() async throws {
    // A bare cancel() closes the host to new peers: they must be rejected
    // through didRejectPeer without reaching the audit window or the peer
    // handler (which would bind them to a session that dies immediately).
    let log = XPCServiceEventLog()
    let audits = Mutex<Int>(0)
    let host = XPCServiceHost(
      XPCConnectionServiceConfiguration(), eventLog: log,
      peerHandler: { _ in audits.withLock { $0 += 1 } })
    host.cancel()

    let listener = XPCConnection(name: nil)
    listener.setEventHandler { object in
      guard xpc_get_type(object) == XPC_TYPE_CONNECTION else { return }
      host.bind(XPCChannel(XPCConnection(xpc_object: object)))
    }
    listener.activate()

    let client = try XPCConnection.unmarshal(from: listener.marshal())
    client.setEventHandler { _ in }
    client.activate()
    client.sendAndForget(message: XPCDictionary())

    let rejection = await log.wait(for: .didRejectPeer, timeout: .seconds(2))
    #expect(rejection != nil)
    #expect(rejection?.errorDescription == nil)
    #expect(audits.withLock { $0 } == 0)
    listener.cancel()
    client.cancel()
  }

  @Test func ExpectShutdownDuringPipelineWaitsForCompletion() async throws {
    // requestShutdown() cancels before running the delegate hook and the
    // completion. A waiter arriving in that window must wait for the
    // pipeline to finish and resolve true — the cancelled-without-pipeline
    // fast path must not fire while a pipeline is in flight.
    let entered = Latch()
    let completed = Latch()
    let release = DispatchSemaphore(value: 0)
    let host = XPCServiceHost(
      XPCConnectionServiceConfiguration(onShutdown: {
        entered.signal()
        release.wait()
      }))
    DispatchQueue.global().async {
      host.requestShutdown()
      completed.signal()
    }
    await entered.wait()  // The pipeline is now inside the delegate hook.

    async let result = host.waitForShutdown(timeout: .seconds(5))
    // The waiter registers while the pipeline is parked in the hook; the
    // sleep only widens that window, the assertion does not depend on it.
    try await Task.sleep(for: .milliseconds(100))
    release.signal()  // Let the pipeline complete.

    #expect(await result)
    await completed.wait()
  }

  @Test func CancelDuringShutdownDoesNotReleasePipelineWaiters() async throws {
    let entered = Latch()
    let completed = Latch()
    let release = DispatchSemaphore(value: 0)
    let host = XPCServiceHost(onShutdown: {
      entered.signal()
      #expect(release.wait(timeout: .now() + 5) == .success)
    })
    DispatchQueue.global().async {
      host.requestShutdown()
      completed.signal()
    }
    await entered.wait()
    let waiter = Task { await host.waitForShutdown(timeout: .seconds(3)) }
    // Repeated cancellations throughout a parked pipeline must never drain
    // its waiters, regardless of whether registration races cancellation.
    DispatchQueue.concurrentPerform(iterations: 100) { _ in host.cancel() }
    release.signal()
    #expect(await waiter.value)
    await completed.wait()
    #expect(await host.waitForShutdown())
  }

  @Test func RawConformerHooksDriveTheServer() async throws {
    let delegate = CountingDelegate()
    let channel = try await RootChannel(DelegateRoot.self, delegate)
    defer { channel.close() }
    let root = try DelegateRoot.connect(using: channel.client)
    #expect(try await root.ping() == "delegate")
    #expect(delegate.audits.withLock { $0 } == 1)
    #expect(delegate.accepted.withLock { $0 } == 1)
  }

  @Test func EventLogRecordsHookSequenceAndShutdown() async throws {
    let log = XPCServiceEventLog()
    let service = try await testService(
      DelegateRoot.self, XPCConnectionServiceConfiguration(), eventLog: log)
    defer { service.close() }

    #expect(try await service.client.root.ping() == "delegate")
    #expect(log.events.map(\.kind) == [.shouldAcceptPeer, .didAcceptPeer])

    service.service.host.requestShutdown()
    #expect(await service.service.host.waitForShutdown(timeout: .seconds(2)))
    // Typed shutdown waits for the registered peer's end notification.
    #expect(log.events.map(\.kind).prefix(2) == [.shouldAcceptPeer, .didAcceptPeer])
    #expect(log.events.map(\.kind).contains(.serviceWillShutdown))
  }

  @Test func WatchdogForceClosesTheServiceAfterDuration() async throws {
    let service = try await testService(DelegateRoot.self, watchdog: .seconds(2))
    #expect(try await service.client.root.ping() == "delegate")

    // The watchdog closes the coordinator so a hung test fails fast:
    // pending calls observe the channel going down.
    await service.waitUntilClosed()
    await #expect(throws: XPCChannelError.self) {
      _ = try await service.client.root.ping()
    }
  }

  @Test func XPCRootTestCoordinatorResolvesRootAndReportsShutdown() async throws {
    let shutdowns = Mutex<Int>(0)
    let service = try await testService(
      DelegateRoot.self,
      XPCConnectionServiceConfiguration(onShutdown: { shutdowns.withLock { $0 += 1 } }))
    defer { service.close() }

    // The client side is a production channel: root resolved at construction.
    #expect(try await service.client.root.ping() == "delegate")

    // A cooperative shutdown on the exposed server never exits the process;
    // it only tears the sessions down and fires the hook exactly once.
    service.service.host.requestShutdown()
    #expect(await service.service.host.waitForShutdown(timeout: .seconds(2)))
    #expect(shutdowns.withLock { $0 } == 1)
  }

  @Test func EventWaitHoldsOccurrenceUntilReached() async throws {
    let log = XPCServiceEventLog()
    log.append(.didAcceptPeer)  // count = 1: below the threshold.

    // Below the threshold the waiter must not resolve early — it expires.
    async let pending = log.wait(for: .didAcceptPeer, occurrence: 2, timeout: .milliseconds(150))
    #expect(await pending == nil)

    // Reaching the threshold resolves the same expectation.
    async let satisfied = log.wait(for: .didAcceptPeer, occurrence: 2, timeout: .seconds(2))
    log.append(.didAcceptPeer)
    #expect(await satisfied != nil)
  }

  @Test func EventWaitSelectsNthEvent() async throws {
    let log = XPCServiceEventLog()
    let service = try await testService(
      DelegateRoot.self, XPCConnectionServiceConfiguration(), eventLog: log)
    defer { service.close() }

    // Two distinct clients, two didAcceptPeer events.
    #expect(try await service.client.root.ping() == "delegate")
    let secondClient = try service.makeClient()
    let second = try DelegateRoot.connect(using: secondClient)
    #expect(try await second.ping() == "delegate")

    #expect(await log.wait(for: .didAcceptPeer, occurrence: 2, timeout: .seconds(2)) != nil)
    let missing = await log.wait(
      for:
        .didAcceptPeer, occurrence: 3, timeout: .milliseconds(150))
    #expect(missing == nil)
  }

  @Test func PeerHandlerThrowRejectsPeerThroughHook() async throws {
    let log = XPCServiceEventLog()
    let host = XPCServiceHost(
      XPCConnectionServiceConfiguration(), eventLog: log,
      peerHandler: { _ in throw XPCDispatchError.unknownActor(.root) })
    // The throw must reject through didRejectPeer — not trap and not accept.
    let listener = XPCConnection(name: nil)
    listener.setEventHandler { object in
      guard xpc_get_type(object) == XPC_TYPE_CONNECTION else { return }
      host.bind(XPCChannel(XPCConnection(xpc_object: object)))
    }
    listener.activate()

    let client = try XPCConnection.unmarshal(from: listener.marshal())
    client.setEventHandler { _ in }
    client.activate()
    client.sendAndForget(message: XPCDictionary())

    let rejection = await log.wait(for: .didRejectPeer, timeout: .seconds(2))
    #expect(rejection != nil)
    #expect(rejection?.errorDescription != nil)
    listener.cancel()
    host.cancel()
    client.cancel()
  }

  @Test func XPCRootTestCoordinatorDropServerPeerEmitsDisconnectAndReestablishes() async throws {
    let log = XPCServiceEventLog()
    let service = try await testService(
      DelegateRoot.self, XPCConnectionServiceConfiguration(), eventLog: log)
    defer { service.close() }
    #expect(try await service.client.root.ping() == "delegate")

    // Drop surfaces on the production event stream...
    service.dropServerPeer()
    // The drop surfaces deterministically in the hook log...
    #expect(await log.wait(for: .peerDidEnd, timeout: .seconds(2)) != nil)

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
    #expect(await log.wait(for: .didAcceptPeer, occurrence: 2, timeout: .seconds(2)) != nil)
  }

  @Test func CoordinatorExpectShutdownResolvesFalseAfterCancel() async throws {
    let service = try await testService(
      DelegateRoot.self,
      XPCConnectionServiceConfiguration(),
      eventLog: XPCServiceEventLog())
    defer { service.close() }

    // The waiter suspends; cancel() must release it with `false` — a
    // bare cancellation resolves its own waiters without a pipeline.
    let waiter = Task { await service.service.host.waitForShutdown(timeout: .seconds(2)) }
    service.service.host.cancel()

    #expect(await waiter.value == false)
    #expect(await !service.service.host.waitForShutdown(timeout: .milliseconds(100)))
  }

  @Test func XPCRootTestCoordinatorRetryingRidesOutServerPeerDrop() async throws {
    let log = XPCServiceEventLog()
    let service = try await testService(
      DelegateRoot.self,
      XPCConnectionServiceConfiguration(),
      eventLog: log)
    defer { service.close() }
    #expect(
      try await service.client.retrying(XPCRetryPolicy.once) { _ in
        try await service.client.root.ping()
      } == "delegate")

    async let peerDidEnd = log.wait(for: .peerDidEnd, timeout: .seconds(2))
    async let acceptedAgain = log.wait(for: .didAcceptPeer, occurrence: 2, timeout: .seconds(2))

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
    #expect(await acceptedAgain != nil)
  }

  @Test func BareCancellationPreventsLaterShutdownHooks() async {
    let calls = Mutex(0)
    let host = XPCServiceHost(onShutdown: { calls.withLock { $0 += 1 } })
    host.cancel()
    host.requestShutdown()
    #expect(await !host.waitForShutdown())
    #expect(calls.withLock { $0 } == 0)
  }

}
