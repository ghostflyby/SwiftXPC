// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// `XPCMessageChannel` backend carried by Apple's `XPCSession`.
///
/// Scope limitations (the session model has no counterpart for these):
/// no peer validation below macOS 26, no peer identity accessors, and no
/// bundled-`.xpc` service hosting — use the C backend (`XPCConnection`)
/// for privileged services. Sending from inside an accept callback traps;
/// the session-side `XPCChannelAcceptor` delivers accepted channels only
/// after the accept decision has returned.
public final class XPCSessionChannel: XPCMessageChannel, @unchecked Sendable {
  private final class IncomingBox: Sendable {
    let handler = Mutex<(@Sendable (XPCIncomingMessage) -> Void)?>(nil)
    let pending = Mutex<[XPCIncomingMessage]>([])
  }

  private enum Session {
    /// An accepted server-side session is already live.
    case accepted(XPCSession)
    /// A dialed session is created on `activate()`.
    case dialed(() throws -> XPCSession)
  }

  private struct Control {
    var activated = false
    var cancelled = false
    var session: XPCSession?
    /// Sends issued before `activate()`, issued once the session goes live
    /// (the channel-level counterpart of libxpc's native pre-activation
    /// buffering on the C backend).
    var pendingSends: [PendingSend] = []
  }

  private enum PendingSend {
    case forget(SendableXPCObject)
    case reply(SendableXPCObject, XPCSendSink)
  }

  /// What a send should do, decided under the control lock.
  private enum SendAction {
    case drop
    case buffered
    case sendNow(XPCSession)
  }

  /// Chained lifecycle handlers. The terminal invalidation chain (once,
  /// clear-on-delivery, disconnection waiters) is the shared
  /// `XPCInvalidationChain`; the interruption slot is session-specific —
  /// single-take, because the channel routes one loss per event.
  private final class LifecycleBox: Sendable {
    let invalidation = XPCInvalidationChain()
    private let interruption = Mutex<(@Sendable () -> Void)?>(nil)

    /// Registers `handler`; returns true when invalidation already happened
    /// and the caller must invoke it now.
    func addInvalidation(_ handler: @escaping @Sendable () -> Void) -> Bool {
      invalidation.add(handler)
    }

    func addInterruption(_ handler: @escaping @Sendable () -> Void) {
      interruption.withLock { slot in
        let previous = slot
        slot = {
          previous?()
          handler()
        }
      }
    }

    /// Marks invalidation delivered, clears both chains (invalidation is
    /// terminal for everything), and returns the invalidation chain to run.
    func takeInvalidation() -> @Sendable () -> Void {
      interruption.withLock { $0 = nil }
      return invalidation.take()
    }

    /// Takes the interruption chain for delivery and marks the channel down
    /// for disconnection waiters (an interruption is a disconnection).
    func takeInterruption() -> @Sendable () -> Void {
      let handler = interruption.withLock { slot in
        let handler = slot
        slot = nil
        return handler
      }
      invalidation.markDisconnected()
      return handler ?? {}
    }
  }

  private let control = Mutex(Control())
  private let source: Session
  private let incoming = IncomingBox()
  private let lifecycle = LifecycleBox()

  deinit {
    cancel()
  }

  /// Creates a channel dialing `endpoint` (for example the wire endpoint of
  /// an acceptor).
  public init(dialing endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil) {
    source = .dialed({
      try XPCSession(endpoint: endpoint, targetQueue: targetQueue, options: [.inactive])
    })
    control.withLock { $0.session = nil }
  }

  /// Creates a channel dialing a launchd-advertised mach service.
  public init(machServiceName: String, targetQueue: DispatchQueue? = nil) {
    source = .dialed({
      try XPCSession(machService: machServiceName, targetQueue: targetQueue, options: [.inactive])
    })
    control.withLock { $0.session = nil }
  }

  /// - Important: invoke during the accept callback only — after the accept
  ///   decision returned, installing handlers traps
  ///   (`xpc_session_set_cancel_handler` misuse).
  package init(accepted session: XPCSession) {
    source = .accepted(session)
    control.withLock { $0.session = session }
    installSessionHandler(session)
  }

  public func setIncomingHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void) {
    incoming.handler.withLock { $0 = handler }
    flushPending()
  }

  public func addInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
    if lifecycle.addInvalidation(handler) {
      handler()
    }
  }

  public func addInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
    lifecycle.addInterruption(handler)
  }

  public func waitForDisconnection() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      lifecycle.invalidation.waitForDisconnection(continuation: cont)
    }
  }

  public func activate() {
    var dialFailed = false
    var toFlush: [PendingSend] = []
    control.withLock { st in
      // A cancelled channel never dials, and a cancel racing this activation
      // cannot slip between dial and store: both run under the same lock, so
      // the session always has an owner that will cancel it.
      guard !st.activated, !st.cancelled else { return }
      st.activated = true
      switch source {
      case .accepted:
        // accepted sessions are live once the accept decision returned
        toFlush = st.pendingSends
        st.pendingSends = []
      case .dialed(let make):
        do {
          let dialed = try make()
          installSessionHandler(dialed)
          st.session = dialed
          try dialed.activate()
          toFlush = st.pendingSends
          st.pendingSends = []
        } catch {
          // A session whose activation failed is auto-cancelled by the
          // runtime; terminal for this channel.
          st.session = nil
          st.cancelled = true
          dialFailed = true
        }
      }
    }
    if dialFailed {
      failPendingSends()
      lifecycle.takeInvalidation()()
      return
    }
    flushPendingSends(toFlush)
  }

  public func cancel() {
    let (session, pending) = control.withLock { st -> (XPCSession?, [PendingSend]) in
      if st.cancelled { return (nil, []) }
      st.cancelled = true
      let pending = st.pendingSends
      st.pendingSends = []
      return (st.session, pending)
    }
    session?.cancel(reason: "channel canceled")
    finishPending(pending)
  }

  /// Fails every still-buffered send with `.invalid` (the channel is
  /// terminal; buffered sends can never be issued).
  private func failPendingSends() {
    finishPending(
      control.withLock { st in
        let pending = st.pendingSends
        st.pendingSends = []
        return pending
      })
  }

  private func finishPending(_ pending: [PendingSend]) {
    for send in pending {
      if case .reply(_, let sink) = send {
        sink.finish(.failure(XPCChannelError.invalid))
      }
    }
  }

  /// Issues buffered sends on the live session. Fire-and-forget entries
  /// send directly; reply entries whose waiter was cancelled while buffered
  /// are skipped (their sink already delivered).
  private func flushPendingSends(_ pending: [PendingSend]) {
    guard let current = control.withLock({ $0.session }) else { return }
    for send in pending {
      switch send {
      case .forget(let boxed):
        do {
          try current.send(message: XPCDictionary(boxed.raw))
        } catch {
          routeSendFailure(error)
        }
      case .reply(let boxed, let sink):
        guard !sink.isDelivered else { continue }
        issueReplySend(current, message: boxed.raw, sink: sink)
      }
    }
  }

  private func issueReplySend(_ session: XPCSession, message: xpc_object_t, sink: XPCSendSink) {
    session.send(
      message: XPCDictionary(message),
      replyHandler: { result in
        switch result {
        case .success(let reply):
          sink.finish(.reply(SendableXPCObject(reply.xpcObject)))
        case .failure(let error):
          sink.finish(
            .failure(error.canRetry ? XPCChannelError.interrupted : XPCChannelError.invalid))
        }
      })
  }

  /// Session channels carry no peer validation: a non-nil requirement fails
  /// closed with `ENOTSUP`, so privileged services never run unvalidated.
  public func applyPeerCodeSigningRequirement(
    _ requirement: String?
  ) throws(XPCPeerRequirementError) {
    if requirement != nil {
      throw XPCPeerRequirementError(status: ENOTSUP)
    }
  }

  public func sendAndForget(_ message: xpc_object_t) {
    let action = control.withLock { st -> SendAction in
      if st.cancelled { return .drop }
      guard let current = st.session, st.activated else {
        st.pendingSends.append(.forget(SendableXPCObject(message)))
        return .buffered
      }
      return .sendNow(current)
    }
    guard case .sendNow(let current) = action else { return }
    // The replyHandler overload registers a reply expectation: when the peer's
    // handler returns no reply, the runtime tears the session down
    // ("Underlying connection interrupted" then "canceled session"). Use the
    // true fire-and-forget overload.
    do {
      try current.send(message: XPCDictionary(message))
    } catch {
      routeSendFailure(error)
    }
  }

  private func routeSendFailure(_ error: any Error) {
    let rich = error as? XPCRichError
    if rich?.canRetry ?? true {
      lifecycle.takeInterruption()()
    } else {
      lifecycle.takeInvalidation()()
    }
  }

  public func send(_ message: xpc_object_t, replyQueue: DispatchQueue?) async throws
    -> xpc_object_t
  {
    let sink = XPCSendSink()
    let boxed = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        sink.install(continuation)
        let action = control.withLock { st -> SendAction in
          if st.cancelled { return .drop }
          guard let current = st.session, st.activated else {
            st.pendingSends.append(.reply(SendableXPCObject(message), sink))
            return .buffered
          }
          return .sendNow(current)
        }
        switch action {
        case .drop:
          sink.finish(.failure(XPCChannelError.invalid))
        case .buffered:
          break
        case .sendNow(let current):
          issueReplySend(current, message: message, sink: sink)
        }
      }
    } onCancel: {
      sink.finish(.failure(CancellationError()))
    }
    return boxed.raw
  }

  private func installSessionHandler(_ session: XPCSession) {
    session.setCancellationHandler { [weak self] error in
      guard let self else { return }
      // A retryable loss maps to the interruption chain; everything else
      // (manual cancel, terminal invalidation) is terminal for a session.
      if error.canRetry {
        self.lifecycle.takeInterruption()()
      } else {
        self.lifecycle.takeInvalidation()()
      }
    }
    session.setIncomingMessageHandler { [incoming] payload in
      let message = XPCIncomingMessage(
        payload: payload.xpcObject,
        replyer: { replyPayload in
          payload.reply(XPCDictionary(replyPayload))
        })
      if let handler = incoming.handler.withLock({ $0 }) {
        handler(message)
      } else {
        incoming.pending.withLock { $0.append(message) }
      }
      return nil
    }
  }

  private func flushPending() {
    let queued = incoming.pending.withLock { pending -> [XPCIncomingMessage] in
      defer { pending.removeAll() }
      return pending
    }
    guard let handler = incoming.handler.withLock({ $0 }) else { return }
    for message in queued {
      handler(message)
    }
  }
}
