// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
@preconcurrency import XPC

/// The transport backend that carries a channel.
public enum XPCChannelTransport: CaseIterable, Sendable {
  /// The C-API connection backend (`XPCConnection`): full feature set —
  /// peer validation, bundled-service hosting, peer identity, transactions.
  case cConnection
  /// Apple's `XPCSession` backend: non-privileged scenarios only (no peer
  /// validation below macOS 26, no bundled-`.xpc` hosting, no peer identity).
  case session

  /// Dials `endpoint` (a `wireEndpoint` token, `XPC_TYPE_ENDPOINT`) over this
  /// transport. Endpoints are backend-agnostic: either transport can dial an
  /// endpoint minted by the other.
  public func channel(dialing endpoint: xpc_object_t) throws -> any XPCMessageChannel {
    switch self {
    case .cConnection: return try XPCConnection.unmarshal(from: endpoint)
    case .session: return XPCSessionChannel(dialing: XPCEndpoint(endpoint))
    }
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
/// channels.
///
/// The `wireEndpoint` is the wire token embedded in payloads (for example the
/// actor-reference format); it is an `XPC_TYPE_ENDPOINT` object, so endpoints
/// minted by one backend can be dialed by the other.
public protocol XPCChannelAcceptor: AnyObject, Sendable {
  /// The channel type delivered by this acceptor.
  associatedtype Channel: XPCMessageChannel

  /// The dialable endpoint token for this acceptor.
  var wireEndpoint: xpc_object_t { get }

  /// Installs the handler invoked for every accepted channel. The delivered
  /// channel type and the configuration/activation window are
  /// backend-specific; see the conforming type's documentation.
  func setAcceptHandler(_ handler: @escaping @Sendable (Channel) -> Void)

  func activate() throws
  func cancel()
}

/// Transport-neutral acceptor seam for consumers that must stay
/// backend-agnostic (for example the actor-reference export path): the
/// operations an export needs from any acceptor, injected as closures so
/// backends keep their native listener levels.
public struct XPCExportAcceptorBox: Sendable {
  public let wireEndpoint: xpc_object_t
  public typealias AcceptHandler =
    @Sendable (
      _ handler: @escaping @Sendable (any XPCMessageChannel) -> Void
    ) -> Void

  public let setAcceptHandler: AcceptHandler
  public let activate: @Sendable () throws -> Void
  public let cancel: @Sendable () -> Void

  public init(
    wireEndpoint: xpc_object_t,
    setAcceptHandler: @escaping AcceptHandler,
    activate: @escaping @Sendable () throws -> Void,
    cancel: @escaping @Sendable () -> Void
  ) {
    self.wireEndpoint = wireEndpoint
    self.setAcceptHandler = setAcceptHandler
    self.activate = activate
    self.cancel = cancel
  }
}

extension XPCConnectionAcceptor {
  /// The transport-neutral seam over this acceptor.
  public var exportBox: XPCExportAcceptorBox {
    XPCExportAcceptorBox(
      wireEndpoint: wireEndpoint,
      setAcceptHandler: { [self] handler in setAcceptHandler { handler($0) } },
      activate: { [self] in try activate() },
      cancel: { [self] in cancel() })
  }
}

extension XPCListenerAcceptor {
  /// The transport-neutral seam over this acceptor.
  public var exportBox: XPCExportAcceptorBox {
    XPCExportAcceptorBox(
      wireEndpoint: wireEndpoint,
      setAcceptHandler: { [self] handler in setAcceptHandler { handler($0) } },
      activate: { [self] in try activate() },
      cancel: { [self] in cancel() })
  }
}

// MARK: - C backend

/// Accepts channels through a C-launchd anonymous listener
/// (`XPCConnection(name: nil)`).
///
/// Delivered channels are *not* activated: configure handlers, then call
/// `activate()` on the channel (mirroring the C handler-before-activate
/// contract). Listener-level error events are dropped; peer validation is the
/// acceptor consumer's responsibility on the delivered channel.
public final class XPCConnectionAcceptor: XPCChannelAcceptor, @unchecked Sendable {
  /// The C backend delivers accepted peers as C connections: the peer channel
  /// type of this acceptor.
  public typealias Channel = XPCConnection

  /// Reference-type storage so the accept handler can be swapped from any
  /// queue after the listener's event handler captured it.
  private final class AcceptHandlerBox: Sendable {
    let handler: Mutex<(@Sendable (XPCConnection) -> Void)?> = Mutex(nil)
  }

  private let listener: XPCConnection
  private let state = AcceptHandlerBox()
  private let activated = Mutex(false)

  /// Creates an anonymous acceptor.
  public init() {
    listener = XPCConnection(name: nil)
    installListenerHandler()
  }

  /// Creates a launchd-named acceptor serving `serviceName`
  /// (a `MachServices` entry in the job's launchd configuration): a
  /// *listener* connection, not a client dial to that service.
  public init(serviceName: String) {
    listener = XPCConnection(machServiceName: serviceName, options: [.listener])
    installListenerHandler()
  }

  /// libxpc traps with `_xpc_api_misuse` ("Activation of a connection
  /// without an event handler.") when a connection is activated before an
  /// event handler was installed, so the handler is installed eagerly here
  /// and `setAcceptHandler` only swaps the boxed closure.
  private func installListenerHandler() {
    listener.setEventHandler { [state] object in
      let peer = XPCConnection(xpc_object: object)
      guard peer.isConnectionObject else {
        return  // listener error events carry no accept semantics
      }
      guard let handler = state.handler.withLock({ $0 }) else { return }
      handler(peer)
    }
  }

  public var wireEndpoint: xpc_object_t {
    xpc_endpoint_create(listener.xpc_object)
  }

  public func setAcceptHandler(_ handler: @escaping @Sendable (XPCConnection) -> Void) {
    state.handler.withLock { $0 = handler }
  }

  /// Startup contract: the listener event handler is installed at
  /// initialization, so `activate()` may be called any time after
  /// `setAcceptHandler`. Idempotent.
  public func activate() throws {
    let first = activated.withLock { current -> Bool in
      if current { return false }
      current = true
      return true
    }
    guard first else { return }
    listener.activate()
  }

  public func cancel() {
    listener.cancel()
  }

  /// libxpc requires a connection to reach the activated+cancelled state
  /// before its last reference is released: dropping a live connection traps
  /// at _xpc_connection_last_xref_cancel, and so does dropping an
  /// unactivated one (probed on macOS 26). XPCConnection.activate()
  /// installs a handler if none was set, so activating here is safe.
  deinit {
    if !activated.withLock({ $0 }) {
      listener.activate()
    }
    listener.cancel()
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
