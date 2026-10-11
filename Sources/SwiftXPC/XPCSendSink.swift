// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// One-shot sink for a send-with-reply continuation: guards against double
/// resumption when task cancellation races the transport's reply callback,
/// and buffers an outcome that arrives before the continuation is installed
/// (cancellation can fire before the suspension starts). A reply arriving
/// after delivery (task cancelled, late reply) is dropped — cancelling the
/// awaiting task does not retract the request.
/// Continuations resume outside the state lock: resumption takes Swift task
/// locks, while Task.cancel holds those locks before entering this sink.
///
/// The reply payload crosses isolation boundaries in the package-private
/// unchecked-`Sendable` box (see README "Raw handles and Sendability"); the
/// receiving side unwraps `.raw` after resuming.
final class XPCSendSink: Sendable {
  enum Outcome {
    case reply(SendableXPCObject)
    case failure(any Error)
  }

  private struct State {
    var continuation: CheckedContinuation<SendableXPCObject, any Error>?
    var outcome: Outcome?
    var delivered = false
  }

  private let state = Mutex(State())
  // Runs outside the lock before each continuation resumes, including rejected
  // late installs. No resumption means zero calls; a normal send calls once.
  // Each late install adds another call, which can overlap an earlier one.
  private let beforeResume: @Sendable () -> Void

  init(beforeResume: @escaping @Sendable () -> Void = {}) {
    self.beforeResume = beforeResume
  }

  /// Installs the continuation; resumes immediately when an outcome (for
  /// example a cancellation) already arrived.
  func install(_ continuation: CheckedContinuation<SendableXPCObject, any Error>) {
    let outcome = state.withLock { st -> Outcome? in
      guard !st.delivered else {
        return .failure(XPCChannelError.invalid)
      }
      st.continuation = continuation
      if let outcome = st.outcome {
        st.continuation = nil
        st.outcome = nil
        st.delivered = true
        return outcome
      }
      return nil
    }
    if let outcome {
      beforeResume()
      continuation.resume(with: outcome)
    }
  }

  /// Delivers `outcome` exactly once: to the installed continuation, or
  /// buffered for a not-yet-installed one. Later calls are dropped.
  func finish(_ outcome: Outcome) {
    let continuation = state.withLock {
      st -> CheckedContinuation<SendableXPCObject, any Error>? in
      guard !st.delivered, st.outcome == nil else { return nil }
      if let continuation = st.continuation {
        st.continuation = nil
        st.delivered = true
        return continuation
      } else {
        st.outcome = outcome
        return nil
      }
    }
    if let continuation {
      beforeResume()
      continuation.resume(with: outcome)
    }
  }

  /// True once an outcome was delivered to the continuation — a pending
  /// buffered send whose waiter was cancelled must not be issued.
  var isDelivered: Bool {
    state.withLock { $0.delivered }
  }
}

extension CheckedContinuation where T == SendableXPCObject, E == any Error {
  fileprivate func resume(with outcome: XPCSendSink.Outcome) {
    switch outcome {
    case .reply(let boxed): resume(returning: boxed)
    case .failure(let error): resume(throwing: error)
    }
  }
}
