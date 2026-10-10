// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// One-shot asynchronous barrier. Resolution never resumes user code under a lock.
final class XPCServiceResult<Value: Sendable>: Sendable {
  private struct State {
    var result: Result<Value, any Error>?
    var waiters: [CheckedContinuation<Value, any Error>] = []
  }
  private let state = Mutex(State())

  func wait() async throws -> Value {
    return try await withCheckedThrowingContinuation { continuation in
      let result = state.withLock { state -> Result<Value, any Error>? in
        if let result = state.result { return result }
        state.waiters.append(continuation)
        return nil
      }
      if let result { continuation.resume(with: result) }
    }
  }

  func finish(_ result: Result<Value, any Error>) {
    let waiters = state.withLock { state in
      guard state.result == nil else { return [CheckedContinuation<Value, any Error>]() }
      state.result = result
      let waiters = state.waiters
      state.waiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume(with: result) }
  }
}

typealias XPCServiceReadiness = XPCServiceResult<Void>
