// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// Transport-level failure model shared by every channel backend.
///
/// `XPCConnection.ConnectionError` remains the C backend's native error type;
/// this top-level enum is the backend-agnostic spelling used by
/// `XPCMessageChannel`.
public enum XPCChannelError: Error, Sendable, Equatable {
  /// The channel is invalid and cannot be re-established.
  case invalid
  /// The peer went away; a later send may re-establish the channel.
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
/// subsequent events. `activate()` is idempotent.
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

  /// Sends a message and awaits its reply.
  /// - Returns: The reply payload (a dictionary).
  func send(_ message: xpc_object_t, replyQueue: DispatchQueue?) async throws
    -> xpc_object_t
}

/// A listener that mints dialable endpoint tokens and delivers accepted
/// channels.
///
/// The `wireEndpoint` is the wire token embedded in payloads (for example the
/// actor-reference format); it is an `XPC_TYPE_ENDPOINT` object, so endpoints
/// minted by one backend can be dialed by the other.
public protocol XPCChannelAcceptor: Sendable {
  /// The dialable endpoint token for this acceptor.
  var wireEndpoint: xpc_object_t { get }

  /// Installs the handler invoked for every accepted channel. Delivered
  /// channels require configuration and `activate()`; see the concrete
  /// backend for its activation window.
  func setAcceptHandler(_ handler: @escaping @Sendable (any XPCMessageChannel) -> Void)

  func activate()
  func cancel()
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
  /// Reference-type storage so the accept handler can be swapped from any
  /// queue after the listener's event handler captured it.
  private final class AcceptHandlerBox: Sendable {
    let handler: Mutex<(@Sendable (any XPCMessageChannel) -> Void)?> = Mutex(nil)
  }

  private let listener: XPCConnection
  private let state = AcceptHandlerBox()

  /// Creates an anonymous acceptor.
  public init() {
    listener = XPCConnection(name: nil)
  }

  /// Creates a launchd-named acceptor serving `serviceName`
  /// (a `MachServices` entry in the job's launchd configuration).
  public init(serviceName: String) {
    listener = XPCConnection(name: serviceName)
  }

  public var wireEndpoint: xpc_object_t {
    xpc_endpoint_create(listener.xpc_object)
  }

  public func setAcceptHandler(_ handler: @escaping @Sendable (any XPCMessageChannel) -> Void) {
    state.handler.withLock { $0 = handler }
    listener.setEventHandler { [state] object in
      let peer = XPCConnection(xpc_object: object)
      guard peer.isConnectionObject else {
        return  // listener error events carry no accept semantics
      }
      guard let handler = state.handler.withLock({ $0 }) else { return }
      handler(peer)
    }
  }

  public func activate() {
    listener.activate()
  }

  public func cancel() {
    listener.cancel()
  }
}

extension XPCConnection: XPCMessageChannel {
  public func setIncomingHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void) {
    setEventHandler { object in
      guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else { return }
      let received = XPCDictionary(object)
      handler(
        XPCIncomingMessage(
          payload: object,
          replyer: { replyPayload in
            guard let reply = XPCDictionary(replyTo: received),
              let remote = received.remoteConnection
            else {
              return
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
