// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// A listener that mints dialable endpoint tokens and delivers accepted
/// channels, independent of the transport backend that carries it. Create
/// with a backend-specific delegate, or use `XPCChannelTransport.acceptor(handler:)`
/// for an uncustomized listener (for example actor-export endpoints).
///
/// The `wireEndpoint` is the wire token embedded in payloads (for example the
/// actor-reference format); it is an `XPC_TYPE_ENDPOINT` object, so endpoints
/// minted by one backend can be dialed by the other.
///
/// Native admission finishes before channels are delivered. Delivered channels
/// require logical activation before incoming traffic is dispatched. Session
/// handlers are installed inside the native callback; buffered messages do not
/// reach service routing until the host binds and activates the channel.
public final class XPCChannelAcceptor: @unchecked Sendable {
  /// A concurrent/reentrant call cannot report another call's unfinished result.
  public enum ActivationError: Error, Sendable, Equatable {
    case inProgress
  }

  private enum Backend {
    /// A C-API listener connection: anonymous, or serving a mach service.
    case connection(XPCConnection)
    /// Apple's `XPCListener`.
    case listener(XPCListener)
  }

  /// Reference-type storage so the accept handler can be swapped from any
  /// queue after the backend's event machinery captured it.
  private final class AcceptHandlerBox: Sendable {
    enum Phase { case inactive, active, cancelled }
    struct State {
      var phase = Phase.inactive
      var activating = false
      var handler: (@Sendable (XPCChannel) -> Void)?
    }
    let state = Mutex(State())
  }

  private let acceptBox = AcceptHandlerBox()
  private let backend: Backend
  private let activationOverride: (@Sendable () throws -> Void)?
  private let queue = DispatchQueue(label: "SwiftXPC.acceptor")

  private enum Admission {
    case connection(any XPCConnectionServiceDelegate)
    case session(any XPCSessionServiceDelegate)
  }

  package convenience init(
    _ delegate: some XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
    service: String? = nil,
    eventLog: XPCServiceEventLog? = nil
  ) throws {
    try self.init(admission: .connection(delegate), service: service, eventLog: eventLog)
  }

  package convenience init(
    sessionDelegate: some XPCSessionServiceDelegate,
    service: String? = nil,
    eventLog: XPCServiceEventLog? = nil
  ) throws {
    try self.init(admission: .session(sessionDelegate), service: service, eventLog: eventLog)
  }

  public convenience init(
    _ delegate: some XPCConnectionServiceDelegate = XPCConnectionServiceConfiguration(),
    service: String? = nil,
    eventLog: XPCServiceEventLog? = nil,
    handler: @escaping @Sendable (XPCChannel) -> Void
  ) throws {
    try self.init(delegate, service: service, eventLog: eventLog)
    setAcceptHandler(handler)
  }

  public convenience init(
    sessionDelegate: some XPCSessionServiceDelegate,
    service: String? = nil,
    eventLog: XPCServiceEventLog? = nil,
    handler: @escaping @Sendable (XPCChannel) -> Void
  ) throws {
    try self.init(sessionDelegate: sessionDelegate, service: service, eventLog: eventLog)
    setAcceptHandler(handler)
  }

  /// Named Session peer validation is a construction capability (macOS 26+).
  /// Keeping it in an available initializer prevents an older deployment from
  /// silently skipping an unavailable Delegate getter. Kernel-dropped requests
  /// do not invoke the native rejection hook.
  @available(macOS 26.0, *)
  public init(
    sessionDelegate: some XPCSessionServiceDelegate,
    service: String,
    requirement: XPCPeerRequirement,
    eventLog: XPCServiceEventLog? = nil,
    handler: @escaping @Sendable (XPCChannel) -> Void
  ) throws {
    activationOverride = nil
    acceptBox.state.withLock { $0.handler = handler }
    backend = .listener(
      try XPCListener(
        service: service, targetQueue: queue, options: [.inactive], requirement: requirement,
        incomingSessionHandler: Self.makeSessionAcceptClosure(
          acceptBox, queue: queue, delegate: sessionDelegate, eventLog: eventLog)))
  }

  convenience init(transport: XPCChannelTransport, service: String?) throws {
    switch transport {
    case .cConnection: try self.init(XPCConnectionServiceConfiguration(), service: service)
    case .session:
      try self.init(sessionDelegate: XPCSessionServiceConfiguration(), service: service)
    }
  }

  private init(admission: Admission, service: String?, eventLog: XPCServiceEventLog?) throws {
    activationOverride = nil
    switch admission {
    case .connection(let delegate):
      // libxpc traps with `_xpc_api_misuse` ("Activation of a connection
      // without an event handler.") when a connection is activated before an
      // event handler was installed, so the routing handler is installed
      // eagerly here; `setAcceptHandler` only swaps the boxed closure.
      let listener: XPCConnection
      if let service {
        listener = XPCConnection(
          machServiceName: service, options: [.listener], dispatchQueue: queue)
      } else {
        listener = XPCConnection(name: nil, dispatchQueue: queue)
      }
      listener.setEventHandler { [acceptBox] object in
        let peer = XPCConnection(xpc_object: object)
        guard peer.isConnectionObject else {
          return  // listener error events carry no accept semantics
        }
        guard acceptBox.state.withLock({ $0.phase == .active && $0.handler != nil }) else {
          rejectXPCConnection(peer, delegate: delegate, eventLog: eventLog, error: nil)
          return
        }
        guard admitXPCConnection(peer, delegate: delegate, eventLog: eventLog) else { return }
        // Audit is user code and may itself cancel the listener.
        guard let handler = acceptBox.state.withLock({ $0.phase == .active ? $0.handler : nil })
        else {
          rejectXPCConnection(peer, delegate: delegate, eventLog: eventLog, error: nil)
          return
        }
        handler(XPCChannel(peer))
      }
      backend = .connection(listener)
    case .session(let delegate):
      // Handlers may only be installed while the session is still inactive,
      // so the accept closure is part of the listener's construction.
      let box = acceptBox
      let handler = Self.makeSessionAcceptClosure(
        box, queue: queue, delegate: delegate, eventLog: eventLog)
      if let service {
        backend = .listener(
          try XPCListener(
            service: service, targetQueue: queue, options: [.inactive],
            incomingSessionHandler: handler))
      } else {
        backend = .listener(
          XPCListener(
            targetQueue: queue, options: [.inactive], incomingSessionHandler: handler))
      }
    }
  }

  /// A static factory so the closure's `@Sendable` conformance is checked
  /// across toolchains (some are stricter about inferring it for local
  /// closures).
  private static func makeSessionAcceptClosure(
    _ box: AcceptHandlerBox, queue: DispatchQueue,
    delegate: any XPCSessionServiceDelegate, eventLog: XPCServiceEventLog?
  )
    -> @Sendable (XPCListener.IncomingSessionRequest)
    -> XPCListener.IncomingSessionRequest.Decision
  {
    { req in
      func reject(_ error: (any Error)?) -> XPCListener.IncomingSessionRequest.Decision {
        let decision = req.reject(reason: error.map(String.init(describing:)) ?? "request rejected")
        eventLog?.append(.didRejectSessionRequest, error: error)
        delegate.didRejectSessionRequest(req, error: error)
        return decision
      }
      guard box.state.withLock({ $0.phase == .active && $0.handler != nil }) else {
        return reject(nil)
      }
      eventLog?.append(.shouldAcceptPeer)
      do {
        guard try delegate.shouldAcceptSessionRequest(req) else { return reject(nil) }
      } catch { return reject(error) }
      guard box.state.withLock({ $0.phase == .active && $0.handler != nil }) else {
        return reject(nil)
      }
      // Sending from inside the accept callback traps; the channel is
      // handed over only after the accept decision has returned.
      let (decision, session) = req.accept(
        incomingMessageHandler: { (_: XPCDictionary) -> XPCDictionary? in nil },
        cancellationHandler: nil)
      let channel = XPCChannel(session: XPCSessionChannel(accepted: session))
      queue.async {
        if let handler = box.state.withLock({ $0.phase == .active ? $0.handler : nil }) {
          handler(channel)
        } else {
          channel.cancel()
        }
      }
      return decision
    }
  }

  public var wireEndpoint: xpc_object_t {
    switch backend {
    case .connection(let listener): xpc_endpoint_create(listener.xpc_object)
    case .listener(let listener): listener.endpoint._endpoint
    }
  }

  package func setAcceptHandler(_ handler: @escaping @Sendable (XPCChannel) -> Void) {
    acceptBox.state.withLock { if $0.phase != .cancelled { $0.handler = handler } }
  }

  // Native-operation injection for deterministic activation failure/reentrancy tests.
  init(testingListener: XPCListener, activation: @escaping @Sendable () throws -> Void) {
    backend = .listener(testingListener)
    activationOverride = activation
  }

  /// Idempotent after activation completes. Overlapping calls throw
  /// `ActivationError.inProgress`; native Session activation can also throw.
  /// Cancellation is terminal and makes later activation a no-op.
  public func activate() throws {
    let first = try acceptBox.state.withLock { state in
      if state.phase == .cancelled { return false }
      if state.activating { throw ActivationError.inProgress }
      guard state.phase == .inactive else { return false }
      state.phase = .active
      state.activating = true
      return true
    }
    guard first else { return }
    var succeeded = false
    defer {
      let cancelled = acceptBox.state.withLock { state in
        state.activating = false
        if state.phase == .cancelled { return true }
        if !succeeded { state.phase = .inactive }
        return false
      }
      // A cancel racing activation hands native teardown to this caller.
      if cancelled { cancelBackend(activateFirst: false) }
    }
    try activateBackend()
    succeeded = true
  }

  private func activateBackend() throws {
    if let activationOverride { return try activationOverride() }
    switch backend {
    case .connection(let listener): listener.activate()
    case .listener(let listener): try listener.activate()
    }
  }

  /// Stops new admission/delivery claims. A handler already claimed by an
  /// incoming callback may finish after cancellation returns. Cancel the host
  /// as well to reject such late bindings. When activation is in progress,
  /// its caller completes native cancellation after activation returns.
  public func cancel() {
    let (handler, activateFirst, cancelNow) = acceptBox.state.withLock {
      state -> ((@Sendable (XPCChannel) -> Void)?, Bool, Bool) in
      guard state.phase != .cancelled else { return (nil, false, false) }
      let inactive = state.phase == .inactive
      state.phase = .cancelled
      let handler = state.handler
      state.handler = nil
      return (handler, inactive, !state.activating)
    }
    if cancelNow { cancelBackend(activateFirst: activateFirst) }
    withExtendedLifetime(handler) {}
  }

  private func cancelBackend(activateFirst: Bool) {
    // Both native listeners must reach activation before final release,
    // including cancellation before the first explicit activate().
    if activateFirst { try? activateBackend() }
    switch backend {
    case .connection(let listener): listener.cancel()
    case .listener(let listener): listener.cancel()
    }
  }

  deinit { cancel() }

}
