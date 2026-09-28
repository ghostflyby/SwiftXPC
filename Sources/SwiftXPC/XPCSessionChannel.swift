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

  private let session: Mutex<XPCSession?>
  private let source: Session
  private let incoming = IncomingBox()
  private let invalidation = Mutex<(@Sendable () -> Void)?>(nil)
  private let interruption = Mutex<(@Sendable () -> Void)?>(nil)
  private let activated = Mutex(false)
  private let cancelled = Mutex(false)

  deinit {
    cancel()
  }

  /// Creates a channel dialing `endpoint` (for example the wire endpoint of
  /// an `XPCListenerAcceptor`).
  public init(dialing endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil) {
    source = .dialed({
      try XPCSession(endpoint: endpoint, targetQueue: targetQueue, options: [.inactive])
    })
    session = Mutex(nil)
  }

  /// Creates a channel dialing a launchd-advertised mach service.
  public init(machServiceName: String, targetQueue: DispatchQueue? = nil) {
    source = .dialed({
      try XPCSession(machService: machServiceName, targetQueue: targetQueue, options: [.inactive])
    })
    session = Mutex(nil)
  }

  /// - Important: invoke during the accept callback only — after the accept
  ///   decision returned, installing handlers traps
  ///   (`xpc_session_set_cancel_handler` misuse).
  package init(accepted session: XPCSession) {
    source = .accepted(session)
    self.session = Mutex(session)
    installSessionHandler(session)
  }

  public func setIncomingHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void) {
    incoming.handler.withLock { $0 = handler }
    flushPending()
  }

  public func addInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
    invalidation.withLock { $0 = handler }
  }

  public func addInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
    interruption.withLock { $0 = handler }
  }

  public func activate() {
    let already = activated.withLock { current -> Bool in
      if current { return true }
      current = true
      return false
    }
    guard !already else { return }
    switch source {
    case .accepted:
      break  // accepted sessions are live once the accept decision returned
    case .dialed(let make):
      do {
        let dialed = try make()
        installSessionHandler(dialed)
        session.withLock { $0 = dialed }
        try dialed.activate()
      } catch {
        invalidation.withLock { $0 }?()
      }
    }
  }

  public func cancel() {
    let first = cancelled.withLock { current -> Bool in
      if current { return false }
      current = true
      return true
    }
    guard first else { return }
    session.withLock { $0 }?.cancel(reason: "channel canceled")
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
    session.withLock { $0 }?.send(message: XPCDictionary(message), replyHandler: { _ in })
  }

  public func send(_ message: xpc_object_t, replyQueue: DispatchQueue?) async throws
    -> xpc_object_t
  {
    let current = session.withLock { $0 }
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
        self.interruption.withLock { $0 }?()
      } else {
        self.invalidation.withLock { $0 }?()
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
    let makeAcceptClosure = {
      (req: XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision in
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
    if let service {
      listener = try XPCListener(
        service: service, targetQueue: nil, options: [.inactive],
        incomingSessionHandler: makeAcceptClosure)
    } else {
      listener = XPCListener(
        targetQueue: nil, options: [.inactive],
        incomingSessionHandler: makeAcceptClosure)
    }
    acceptHandlerBox = handlerBox
  }

  private final class AcceptHandlerBox: Sendable {
    let handler = Mutex<(@Sendable (any XPCMessageChannel) -> Void)?>(nil)
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

  public func setAcceptHandler(_ handler: @escaping @Sendable (any XPCMessageChannel) -> Void) {
    acceptHandlerBox.handler.withLock { $0 = handler }
  }

  public func activate() {
    try? listener.activate()
  }

  public func cancel() {
    listener.cancel()
  }
}
