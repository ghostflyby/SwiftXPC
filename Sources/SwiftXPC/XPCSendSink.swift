// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// One-shot sink for a send-with-reply continuation: guards against double
/// resumption when task cancellation races the transport's reply callback,
/// and buffers an outcome that arrives before the continuation is installed
/// (cancellation can fire before the suspension starts). A reply arriving
/// after delivery (task cancelled, late reply) is dropped — cancelling the
/// awaiting task does not retract the request.
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

  /// Installs the continuation; resumes immediately when an outcome (for
  /// example a cancellation) already arrived.
  func install(_ continuation: CheckedContinuation<SendableXPCObject, any Error>) {
    state.withLock { st in
      guard !st.delivered else {
        continuation.resume(throwing: XPCChannelError.invalid)
        return
      }
      st.continuation = continuation
      if let outcome = st.outcome {
        st.continuation = nil
        st.outcome = nil
        st.delivered = true
        continuation.resume(with: outcome)
      }
    }
  }

  /// Delivers `outcome` exactly once: to the installed continuation, or
  /// buffered for a not-yet-installed one. Later calls are dropped.
  func finish(_ outcome: Outcome) {
    state.withLock { st in
      guard !st.delivered, st.outcome == nil else { return }
      if let continuation = st.continuation {
        st.continuation = nil
        st.delivered = true
        continuation.resume(with: outcome)
      } else {
        st.outcome = outcome
      }
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
