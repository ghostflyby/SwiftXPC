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
/// `XPCListenerAcceptor` delivers accepted channels only after the accept
/// decision has returned.
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
  }

  /// Chained lifecycle handlers, mirroring `XPCConnection`'s semantics:
  /// registrations chain (previous runs first), invalidation is delivered
  /// exactly once, and a handler registered after invalidation runs
  /// immediately. Handlers are cleared on delivery so captured references
  /// (including channels) do not form permanent retain cycles.
  private final class LifecycleBox: Sendable {
    private struct State {
      var invalidation: (@Sendable () -> Void)?
      var interruption: (@Sendable () -> Void)?
      var invalidationDelivered = false
    }

    private let state = Mutex(State())

    /// Registers `handler`; returns true when invalidation already happened
    /// and the caller must invoke it now.
    func addInvalidation(_ handler: @escaping @Sendable () -> Void) -> Bool {
      state.withLock { state in
        if state.invalidationDelivered { return true }
        let previous = state.invalidation
        state.invalidation = {
          previous?()
          handler()
        }
        return false
      }
    }

    func addInterruption(_ handler: @escaping @Sendable () -> Void) {
      state.withLock { state in
        let previous = state.interruption
        state.interruption = {
          previous?()
          handler()
        }
      }
    }

    /// Marks invalidation delivered and returns the chained handler to run
    /// (already cleared from storage).
    func takeInvalidation() -> @Sendable () -> Void {
      state.withLock { state in
        state.invalidationDelivered = true
        let handler = state.invalidation
        state.invalidation = nil
        state.interruption = nil
        return handler ?? {}
      }
    }

    func takeInterruption() -> @Sendable () -> Void {
      state.withLock { state in
        let handler = state.interruption
        state.interruption = nil
        return handler ?? {}
      }
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
  /// an `XPCListenerAcceptor`).
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

  public func activate() {
    var dialFailed = false
    control.withLock { st in
      // A cancelled channel never dials, and a cancel racing this activation
      // cannot slip between dial and store: both run under the same lock, so
      // the session always has an owner that will cancel it.
      guard !st.activated, !st.cancelled else { return }
      st.activated = true
      switch source {
      case .accepted:
        break  // accepted sessions are live once the accept decision returned
      case .dialed(let make):
        do {
          let dialed = try make()
          installSessionHandler(dialed)
          st.session = dialed
          try dialed.activate()
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
      lifecycle.takeInvalidation()()
    }
  }

  public func cancel() {
    let session = control.withLock { st -> XPCSession? in
      if st.cancelled { return nil }
      st.cancelled = true
      return st.session
    }
    session?.cancel(reason: "channel canceled")
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
    guard let current = control.withLock({ $0.session }) else { return }
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
    let current = control.withLock { $0.session }
    guard let current else {
      throw XPCChannelError.invalid
    }
    return try await withCheckedThrowingContinuation { continuation in
      current.send(
        message: XPCDictionary(message),
        replyHandler: { result in
          switch result {
          case .success(let reply):
            continuation.resume(returning: reply.xpcObject)
          case .failure(let error):
            continuation.resume(throwing: error.canRetry ? XPCChannelError.interrupted : .invalid)
          }
        })
    }
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

/// Accepts channels through Apple's `XPCListener`: anonymous by default, or
/// serving a launchd-advertised mach service name.
///
/// Delivered channels are live (no `activate()` required) and are handed to
/// the accept handler only after the accept decision returned — sending from
/// inside the accept callback would trap.
public final class XPCListenerAcceptor: XPCChannelAcceptor, @unchecked Sendable {
  /// The session backend delivers accepted peers as session channels.
  public typealias Channel = XPCSessionChannel

  private let listener: XPCListener

  /// Creates an anonymous acceptor.
  public convenience init() throws {
    try self.init(service: nil)
  }

  /// Creates an acceptor serving `serviceName` (a `MachServices` entry in the
  /// job's launchd configuration) or an anonymous one when `serviceName` is
  /// nil.
  public init(service: String?) throws {
    let handlerBox = AcceptHandlerBox()
    if let service {
      listener = try XPCListener(
        service: service, targetQueue: nil, options: [.inactive],
        incomingSessionHandler: Self.makeAcceptClosure(handlerBox))
    } else {
      listener = XPCListener(
        targetQueue: nil, options: [.inactive],
        incomingSessionHandler: Self.makeAcceptClosure(handlerBox))
    }
    acceptHandlerBox = handlerBox
  }

  private final class AcceptHandlerBox: Sendable {
    let handler = Mutex<(@Sendable (XPCSessionChannel) -> Void)?>(nil)
  }

  private static func makeAcceptClosure(
    _ handlerBox: AcceptHandlerBox
  ) -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision
  {
    { req in
      let (decision, session) = req.accept(
        incomingMessageHandler: { (_: XPCDictionary) -> XPCDictionary? in return nil },
        cancellationHandler: nil)
      let channel = XPCSessionChannel(accepted: session)
      DispatchQueue.global().async {
        if let accept = handlerBox.handler.withLock({ $0 }) {
          accept(channel)
        }
      }
      return decision
    }
  }

  private let acceptHandlerBox: AcceptHandlerBox

  /// An activated listener traps on deallocation in two ways: dealloc while
  /// active, and dispose-after-cancel racing a pending accept delivery. The
  /// object is tiny — retain it permanently so it never deallocates.
  deinit {
    listener.cancel()
    _ = Unmanaged.passRetained(listener)
  }

  public var wireEndpoint: xpc_object_t {
    listener.endpoint._endpoint
  }

  /// The dialable endpoint of the underlying listener.
  public var listenerEndpoint: XPCEndpoint {
    listener.endpoint
  }

  public func setAcceptHandler(_ handler: @escaping @Sendable (XPCSessionChannel) -> Void) {
    acceptHandlerBox.handler.withLock { $0 = handler }
  }

  public func activate() throws {
    let first = activatedFlag.withLock { current -> Bool in
      if current { return false }
      current = true
      return true
    }
    guard first else { return }
    try listener.activate()
  }

  private let activatedFlag = Mutex(false)

  public func cancel() {
    listener.cancel()
  }
}
