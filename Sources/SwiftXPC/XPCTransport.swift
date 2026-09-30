// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
@preconcurrency import XPC

/// The transport backend that carries a channel — also the single
/// selection point for entry paths that cannot take an explicit backend
/// parameter: dialing and accepting factories live here, the process-wide
/// default (`processDefault`) backs them, and endpoints are backend-agnostic
/// so either backend can interoperate with the other.
public enum XPCChannelTransport: CaseIterable, Sendable {
  /// The C-API connection backend (`XPCConnection`): full feature set —
  /// peer validation, bundled-service hosting, peer identity, transactions.
  case cConnection
  /// Apple's `XPCSession` backend: non-privileged scenarios only (no peer
  /// validation below macOS 26, no bundled-`.xpc` hosting, no peer identity).
  case session

  private static let _processDefault = Mutex(XPCChannelTransport.cConnection)

  /// The process-wide default backend, read where no explicit backend can
  /// be passed (actor-reference import decodes through a fixed
  /// `unmarshal(from:)` signature) and used as the default of the
  /// parameters that can. Set it before the first channel operation; later
  /// changes only affect subsequent constructions. Defaults to the C
  /// backend.
  public static var processDefault: XPCChannelTransport {
    get { _processDefault.withLock { $0 } }
    set { _processDefault.withLock { $0 = newValue } }
  }

  /// Dials `endpoint` (a `wireEndpoint` token, `XPC_TYPE_ENDPOINT`) over this
  /// transport. Endpoints are backend-agnostic: either transport can dial an
  /// endpoint minted by the other.
  public func channel(dialing endpoint: xpc_object_t) throws -> any XPCMessageChannel {
    switch self {
    case .cConnection: return try XPCConnection.unmarshal(from: endpoint)
    case .session: return XPCSessionChannel(dialing: XPCEndpoint(endpoint))
    }
  }

  /// Creates an acceptor over this transport: anonymous when `service` is
  /// nil, or serving the launchd-advertised mach service name (a
  /// `MachServices` entry in the job's launchd configuration) otherwise.
  public func acceptor(service: String? = nil) throws -> XPCChannelAcceptor {
    try XPCChannelAcceptor(transport: self, service: service)
  }
}

/// A peer code signing requirement install failure (errno-style `status`,
/// e.g. `ENOTSUP` on backends without peer validation support).
public struct XPCPeerRequirementError: Error, Sendable {
  public let status: Int32
  public init(status: Int32) {
    self.status = status
  }
}

/// Transport-level failure model shared by every channel backend: the single
/// error vocabulary of `XPCMessageChannel` and of the C surface's sends.
public enum XPCChannelError: Error, Sendable, Equatable {
  /// The channel is invalid and cannot be re-established.
  case invalid
  /// The peer went away. On the C backend a later send may transparently
  /// re-establish the channel (named services and live endpoint listeners);
  /// the session backend never re-establishes — treat it as terminal there.
  case interrupted
  /// The peer failed this channel's code signing requirement.
  case peerCodeSigningRequirement
}

/// An incoming message together with the capability to answer it.
///
/// Backends fuse their native reply mechanics into `reply(_:)`: the C backend
/// uses `xpc_dictionary_create_reply` + send on the remote connection, the
/// session backend uses the received dictionary's own reply. `reply` may be
/// called from any queue, after the incoming handler has returned, and at most
/// once per message.
public struct XPCIncomingMessage: @unchecked Sendable {
  /// The message payload (a dictionary).
  public let payload: xpc_object_t

  private let replyer: @Sendable (xpc_object_t) -> Void

  init(payload: xpc_object_t, replyer: @escaping @Sendable (xpc_object_t) -> Void) {
    self.payload = payload
    self.replyer = replyer
  }

  /// Answers the message. A reply to a message that does not expect one is
  /// dropped by the transport.
  public func reply(_ payload: xpc_object_t) {
    replyer(payload)
  }
}

/// A bidirectional message channel between two processes, independent of the
/// transport backend that carries it.
///
/// Configure the incoming and lifecycle handlers, then call `activate()`.
/// Handlers may also be installed after activation; they take effect for
/// subsequent events. `activate()` is idempotent. Sends issued before
/// `activate()` are buffered and issued on activation (probed on both
/// backends; the session backend buffers in the channel, the C backend in
/// libxpc).
///
/// Backend availability differs (see `XPCSessionChannel`): the C backend
/// supports peer validation, bundled-service hosting, and peer identity
/// accessors; the session backend is limited to non-privileged scenarios.
public protocol XPCMessageChannel: Sendable {
  /// Installs the handler for incoming request messages. Error and lifecycle
  /// events are delivered through the dedicated handlers instead.
  func setIncomingHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void)

  /// Registers a handler invoked when the channel is invalidated
  /// (terminally unusable). Chained like `XPCConnection.addInvalidationHandler`.
  func addInvalidationHandler(_ handler: @escaping @Sendable () -> Void)

  /// Registers a handler invoked when the peer went away but the channel may
  /// recover on a later send. Chained like
  /// `XPCConnection.addInterruptionHandler`.
  func addInterruptionHandler(_ handler: @escaping @Sendable () -> Void)

  func activate()
  func cancel()

  /// Sends a message without expecting a reply.
  func sendAndForget(_ message: xpc_object_t)

  /// Sends a message and awaits its reply. Suspending on a cancelled task
  /// throws `CancellationError` without retracting the request: the late
  /// reply is dropped, and the channel stays usable.
  /// - Returns: The reply payload (a dictionary).
  func send(_ message: xpc_object_t, replyQueue: DispatchQueue?) async throws
    -> xpc_object_t

  /// Installs a kernel-enforced peer code signing requirement on a
  /// not-yet-activated channel. No-op for nil; backends without peer
  /// validation throw for non-nil requirements (fail-closed).
  func applyPeerCodeSigningRequirement(_ requirement: String?) throws(XPCPeerRequirementError)
}

/// A listener that mints dialable endpoint tokens and delivers accepted
/// channels, independent of the transport backend that carries it. Create
/// through `XPCChannelTransport.acceptor(service:)`.
///
/// The `wireEndpoint` is the wire token embedded in payloads (for example the
/// actor-reference format); it is an `XPC_TYPE_ENDPOINT` object, so endpoints
/// minted by one backend can be dialed by the other.
///
/// The one semantic difference between backends sits at the accept decision
/// point: the C backend delivers channels *before activation* — configure
/// handlers, then call `activate()` on the channel (the C
/// handler-before-activate contract). The session backend accepts the peer
/// inside the listener callback and delivers an already-live channel;
/// `activate()` is an idempotent no-op on it, and rejecting means cancelling
/// it. Listener-level error events are dropped; peer validation is the
/// acceptor consumer's responsibility on the delivered channel.
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
    let handler = Mutex<(@Sendable (any XPCMessageChannel) -> Void)?>(nil)
  }

  private let acceptBox = AcceptHandlerBox()
  private let backend: Backend
  private let activated = Mutex(false)

  init(transport: XPCChannelTransport, service: String?) throws {
    switch transport {
    case .cConnection:
      // libxpc traps with `_xpc_api_misuse` ("Activation of a connection
      // without an event handler.") when a connection is activated before an
      // event handler was installed, so the routing handler is installed
      // eagerly here; `setAcceptHandler` only swaps the boxed closure.
      let listener: XPCConnection
      if let service {
        listener = XPCConnection(machServiceName: service, options: [.listener])
      } else {
        listener = XPCConnection(name: nil)
      }
      listener.setEventHandler { [acceptBox] object in
        let peer = XPCConnection(xpc_object: object)
        guard peer.isConnectionObject else {
          return  // listener error events carry no accept semantics
        }
        guard let handler = acceptBox.handler.withLock({ $0 }) else { return }
        handler(peer)
      }
      backend = .connection(listener)
    case .session:
      // Handlers may only be installed while the session is still inactive,
      // so the accept closure is part of the listener's construction.
      let box = acceptBox
      if let service {
        backend = .listener(
          try XPCListener(
            service: service, targetQueue: nil, options: [.inactive],
            incomingSessionHandler: Self.makeSessionAcceptClosure(box)))
      } else {
        backend = .listener(
          XPCListener(
            targetQueue: nil, options: [.inactive],
            incomingSessionHandler: Self.makeSessionAcceptClosure(box)))
      }
    }
  }

  /// A static factory so the closure's `@Sendable` conformance is checked
  /// across toolchains (some are stricter about inferring it for local
  /// closures).
  private static func makeSessionAcceptClosure(
    _ box: AcceptHandlerBox
  )
    -> @Sendable (XPCListener.IncomingSessionRequest)
    -> XPCListener.IncomingSessionRequest.Decision
  {
    { req in
      // Sending from inside the accept callback traps; the channel is
      // handed over only after the accept decision has returned.
      let (decision, session) = req.accept(
        incomingMessageHandler: { (_: XPCDictionary) -> XPCDictionary? in nil },
        cancellationHandler: nil)
      let channel = XPCSessionChannel(accepted: session)
      DispatchQueue.global().async {
        if let handler = box.handler.withLock({ $0 }) {
          handler(channel)
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

  public func setAcceptHandler(_ handler: @escaping @Sendable (any XPCMessageChannel) -> Void) {
    acceptBox.handler.withLock { $0 = handler }
  }

  /// Idempotent. Activating a session listener can fail (for example an
  /// unknown mach service); C activation never fails.
  public func activate() throws {
    let first = activated.withLock { current -> Bool in
      if current { return false }
      current = true
      return true
    }
    guard first else { return }
    switch backend {
    case .connection(let listener): listener.activate()
    case .listener(let listener): try listener.activate()
    }
  }

  public func cancel() {
    switch backend {
    case .connection(let listener): listener.cancel()
    case .listener(let listener): listener.cancel()
    }
  }

  deinit {
    switch backend {
    case .connection(let listener):
      // libxpc requires a connection to reach the activated+cancelled state
      // before its last reference is released: dropping a live connection
      // traps at _xpc_connection_last_xref_cancel, and so does dropping an
      // unactivated one (probed on macOS 26). XPCConnection.activate()
      // installs a handler if none was set, so activating here is safe.
      if !activated.withLock({ $0 }) {
        listener.activate()
      }
      listener.cancel()
    case .listener(let listener):
      // An activated listener traps on deallocation in two ways: dealloc
      // while active, and dispose-after-cancel racing a pending accept
      // delivery. The object is tiny — retain it permanently.
      listener.cancel()
      _ = Unmanaged.passRetained(listener)
    }
  }
}

extension XPCConnection {
  public func applyPeerCodeSigningRequirement(
    _ requirement: String?
  ) throws(XPCPeerRequirementError) {
    guard let requirement else { return }
    try setPeerCodeSigningRequirement(requirement)
  }
}

extension XPCConnection: XPCMessageChannel {
  public func setIncomingHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void) {
    setEventHandler { object in
      guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else { return }
      // libxpc handles are thread-safe: the box carries the raw handle
      // across the reply closure's isolation boundary.
      let box = SendableXPCObject(object)
      handler(
        XPCIncomingMessage(
          payload: box.raw,
          replyer: { replyPayload in
            let received = XPCDictionary(box.raw)
            guard var reply = XPCDictionary(replyTo: XPCDictionary(box.raw)),
              let remote = received.remoteConnection
            else { return }
            // create_reply only binds the destination; merge the envelope
            // payload keys into it before sending.
            XPCDictionary(replyPayload).forEach { key, value in
              reply[key] = value
            }
            remote.sendAndForget(message: reply)
          }))
    }
  }

  public func sendAndForget(_ message: xpc_object_t) {
    xpc_connection_send_message(xpc_object, message)
  }

  public func send(_ message: xpc_object_t, replyQueue: DispatchQueue?) async throws
    -> xpc_object_t
  {
    try await send(message: XPCDictionary(message), replyQueue: replyQueue)
  }
}
