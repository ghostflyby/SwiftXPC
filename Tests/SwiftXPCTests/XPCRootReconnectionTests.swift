// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import Synchronization
import SwiftXPC
import SwiftXPCMacros
import Testing

@available(macOS 15, *)
private final class AttemptCounter: @unchecked Sendable {
  let count = Mutex<Int>(0)

  /// Runs `body`, making it fail with a connection error `failures` times
  /// before letting it succeed (or exhausting on the last attempt).
  func failing<T>(_ failures: Int, body: (Int) async throws -> T) async throws -> T {
    let attempt = count.withLock { value -> Int in
      value += 1
      return value
    }
    if attempt <= failures {
      throw XPCConnection.ConnectionError.invalid
    }
    return try await body(attempt)
  }
}

// MARK: - Retry policy unit behavior

@Test func RetryingSucceedsAfterTransientConnectionErrors() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ReconnectRoot.self)
  let handle = try XPCRootConnection<ReconnectRoot>.connect(using: channel.client)
  defer { handle.close(); channel.close() }

  let counter = AttemptCounter()
  let result = try await handle.retrying(.resilient) { _ -> String in
    try await counter.failing(2) { attempt in "attempt-\(attempt)" }
  }
  #expect(result == "attempt-3")
}

@Test func RetryingDoesNotRetryBusinessErrors() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ReconnectRoot.self)
  let handle = try XPCRootConnection<ReconnectRoot>.connect(using: channel.client)
  defer { handle.close(); channel.close() }

  struct BusinessError: Error {}
  let attempts = Mutex<Int>(0)
  do {
    _ = try await handle.retrying(.resilient) { _ -> Int in
      attempts.withLock { $0 += 1 }
      throw BusinessError()
    }
    Issue.record("Expected business error to propagate")
  } catch is BusinessError {
    #expect(attempts.withLock { $0 } == 1)
  }
}

@Test func RetryingExhaustsAttemptsAndThrowsLastError() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ReconnectRoot.self)
  let handle = try XPCRootConnection<ReconnectRoot>.connect(using: channel.client)
  defer { handle.close(); channel.close() }

  let policy = XPCRetryPolicy(
    maxAttempts: 3, initialBackoff: .milliseconds(1), multiplier: 1, maxBackoff: .milliseconds(1))
  let attempts = Mutex<Int>(0)
  do {
    _ = try await handle.retrying(policy) { _ -> Never in
      attempts.withLock { $0 += 1 }
      throw XPCConnection.ConnectionError.invalid
    }
    Issue.record("Expected retry exhaustion")
  } catch XPCConnection.ConnectionError.invalid {
    #expect(attempts.withLock { $0 } == 3)
  }
}

// MARK: - Lifecycle events and peer callbacks

@Test func DisconnectEventFiresWhenServicePeerDies() async throws {
  guard #available(macOS 15, *) else { return }
  let channel = try RootChannel(ReconnectRoot.self)
  let handle = try XPCRootConnection<ReconnectRoot>.connect(using: channel.client)
  defer { handle.close(); channel.close() }

  // Root call works through the handle.
  let pong = try await handle.retrying { _ in
    try await handle.root.ping()
  }
  #expect(pong == "root")

  // Kill the server-side root channel; the client observes disconnection.
  channel.killServerPeer()

  let event = await nextEvent(from: handle.events, expecting: .disconnected)
  #expect(event == .disconnected)
}

@Test func ServerFiresPeerAcceptAndEndCallbacks() async throws {
  guard #available(macOS 15, *) else { return }
  let accepted = Mutex<Int>(0)
  let ended = Mutex<Int>(0)

  let channel = try RootChannel(
    ReconnectRoot.self,
    onPeerAccept: { _ in accepted.withLock { $0 += 1 } },
    onPeerEnd: { _ in ended.withLock { $0 += 1 } }
  )
  let handle = try XPCRootConnection<ReconnectRoot>.connect(using: channel.client)
  defer { handle.close(); channel.close() }

  _ = try await handle.root.ping()
  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline, accepted.withLock { $0 } == 0 {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(accepted.withLock { $0 } >= 1)

  channel.client.cancel()
  deadlineMillis: for _ in 0..<100 {
    if ended.withLock({ $0 }) >= 1 { break deadlineMillis }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(ended.withLock { $0 } >= 1)
}

// MARK: - Root channel

@available(macOS 15, *)
@XPCService
distributed actor ReconnectRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem

  distributed func ping() -> String {
    "root"
  }
}

@available(macOS 15, *)
private func nextEvent(
  from stream: AsyncStream<XPCRootConnectionEvent>,
  expecting expected: XPCRootConnectionEvent
) async -> XPCRootConnectionEvent? {
  await withTaskGroup(of: XPCRootConnectionEvent?.self) { group in
    group.addTask {
      for await event in stream where event == expected {
        return event
      }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(5))
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}
