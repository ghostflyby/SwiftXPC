// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// Shared terminal-invalidation machinery for channel backends: chained
/// registration (previous handler first), delivery exactly once with late
/// registrants invoked immediately, handlers cleared on delivery so captured
/// references (channels, connections) do not form permanent retain cycles,
/// and disconnection waiters resumed when the channel goes down — through
/// invalidation or a backend-reported disconnecting event (an interruption).
final class XPCInvalidationChain: Sendable {
  private struct State {
    var handler: (@Sendable () -> Void)?
    var delivered = false
    var disconnected = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  /// Registers `handler`; returns true when invalidation already happened
  /// and the caller must invoke the handler now.
  func add(_ handler: @escaping @Sendable () -> Void) -> Bool {
    state.withLock { st in
      if st.delivered { return true }
      let previous = st.handler
      st.handler = {
        previous?()
        handler()
      }
      return false
    }
  }

  /// Marks invalidation delivered, clears the chain, resumes disconnection
  /// waiters, and returns the chained handler for the caller to run outside
  /// any lock.
  func take() -> @Sendable () -> Void {
    let (handler, waiters) = state.withLock {
      st -> (@Sendable () -> Void, [CheckedContinuation<Void, Never>]) in
      st.delivered = true
      st.disconnected = true
      let handler = st.handler
      st.handler = nil
      let waiters = st.waiters
      st.waiters.removeAll()
      return (handler ?? {}, waiters)
    }
    waiters.forEach { $0.resume() }
    return handler
  }

  /// Marks the channel down without invalidation (an interruption also
  /// counts as a disconnection) and resumes the waiters.
  func markDisconnected() {
    let waiters = state.withLock { st -> [CheckedContinuation<Void, Never>] in
      st.disconnected = true
      let waiters = st.waiters
      st.waiters.removeAll()
      return waiters
    }
    waiters.forEach { $0.resume() }
  }

  /// Registers a continuation resumed when the channel went down —
  /// invalidated or interrupted. Resumes immediately when either was already
  /// delivered. Never polls — the wait suspends until the disconnecting
  /// event itself.
  func waitForDisconnection(continuation: CheckedContinuation<Void, Never>) {
    let down = state.withLock { st in
      if st.delivered || st.disconnected { return true }
      st.waiters.append(continuation)
      return false
    }
    if down {
      continuation.resume()
    }
  }
}
