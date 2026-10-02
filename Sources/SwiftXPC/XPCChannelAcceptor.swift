// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// A listener that mints dialable endpoint tokens and delivers accepted
/// channels, independent of the transport backend that carries it. Create
/// through `XPCChannelTransport.acceptor(service:)`.
///
/// The `wireEndpoint` is the wire token embedded in payloads (for example the
/// actor-reference format); it is an `XPC_TYPE_ENDPOINT` object, so endpoints
/// minted by one backend can be dialed by the other.
///
/// Delivered channels require logical activation before incoming traffic is
/// dispatched. Session peers are accepted natively during the callback;
/// rejection cancels them, while their messages remain buffered.
public final class XPCChannelAcceptor: @unchecked Sendable {
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
  private let queue = DispatchQueue(label: "SwiftXPC.acceptor")

  init(transport: XPCChannelTransport, service: String?) throws {
    switch transport {
    case .cConnection:
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
        guard let handler = acceptBox.state.withLock({ $0.phase == .active ? $0.handler : nil })
        else {
          peer.activate()
          peer.cancel()
          return
        }
        handler(XPCChannel(peer))
      }
      backend = .connection(listener)
    case .session:
      // Handlers may only be installed while the session is still inactive,
      // so the accept closure is part of the listener's construction.
      let box = acceptBox
      if let service {
        backend = .listener(
          try XPCListener(
            service: service, targetQueue: queue, options: [.inactive],
            incomingSessionHandler: Self.makeSessionAcceptClosure(box, queue: queue)))
      } else {
        backend = .listener(
          XPCListener(
            targetQueue: queue, options: [.inactive],
            incomingSessionHandler: Self.makeSessionAcceptClosure(box, queue: queue)))
      }
    }
  }

  /// A static factory so the closure's `@Sendable` conformance is checked
  /// across toolchains (some are stricter about inferring it for local
  /// closures).
  private static func makeSessionAcceptClosure(
    _ box: AcceptHandlerBox, queue: DispatchQueue
  )
    -> @Sendable (XPCListener.IncomingSessionRequest)
    -> XPCListener.IncomingSessionRequest.Decision
  {
    { req in
      guard box.state.withLock({ $0.phase == .active && $0.handler != nil }) else {
        return req.reject(reason: "listener closed or has no accept handler")
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

  public func setAcceptHandler(_ handler: @escaping @Sendable (XPCChannel) -> Void) {
    acceptBox.state.withLock { if $0.phase != .cancelled { $0.handler = handler } }
  }

  /// Idempotent. Session listener activation can throw; cancellation is terminal.
  public func activate() throws {
    let first = acceptBox.state.withLock { state in
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
    switch backend {
    case .connection(let listener): listener.activate()
    case .listener(let listener): try listener.activate()
    }
  }

  /// Stops accepting immediately. When activation is in progress, its caller
  /// completes native cancellation after activation returns.
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
