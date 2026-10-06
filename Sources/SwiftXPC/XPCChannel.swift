// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// Transport-level failure model shared by every channel backend: the single
/// error vocabulary of `XPCChannel` and of the C surface's sends.
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

  private let replied = ReplyState()
  private let replyer: @Sendable (xpc_object_t) -> Void

  init(payload: xpc_object_t, replyer: @escaping @Sendable (xpc_object_t) -> Void) {
    self.payload = payload
    self.replyer = replyer
  }

  private final class ReplyState: Sendable {
    let sent = Mutex(false)
  }

  /// Answers once across all copies; duplicate replies are ignored.
  /// Replies to fire-and-forget traffic are dropped by the transport.
  public func reply(_ payload: xpc_object_t) {
    guard
      replied.sent.withLock({ sent in
        if sent { return false }
        sent = true
        return true
      })
    else { return }
    replyer(payload)
  }
}

/// An owned bidirectional channel. Configure handlers, then activate.
/// Sends before activation buffer; cancel is terminal and safe in any state.
/// Awaiting a reply supports task cancellation without closing the channel.
public final class XPCChannel: Sendable {
  private enum Backend: Sendable {
    case connection(XPCConnection)
    case session(XPCSessionChannel)
  }

  private let backend: Backend

  /// Adopts a native C connection. The channel cancels it on deinitialization.
  public init(_ connection: XPCConnection) {
    backend = .connection(connection)
  }

  init(session: XPCSessionChannel) {
    backend = .session(session)
  }

  deinit { cancel() }

  public var transport: XPCChannelTransport {
    switch backend {
    case .connection: .cConnection
    case .session: .session
    }
  }

  /// Native interop for C-only operations, including peer requirements.
  public var connection: XPCConnection? {
    if case .connection(let connection) = backend { return connection }
    return nil
  }

  public func setIncomingHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void) {
    switch backend {
    case .connection(let connection): connection.setIncomingHandler(handler)
    case .session(let session): session.setIncomingHandler(handler)
    }
  }

  public func addInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
    switch backend {
    case .connection(let connection): connection.addInvalidationHandler(handler)
    case .session(let session): session.addInvalidationHandler(handler)
    }
  }

  // C-only signal used by DistributedXPC's root handle; not a common API.
  package func addInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
    connection?.addInterruptionHandler(handler)
  }

  /// Waits for the first disconnection, including an earlier interruption.
  public func waitForDisconnection() async {
    switch backend {
    case .connection(let connection): await connection.waitForDisconnection()
    case .session(let session): await session.waitForDisconnection()
    }
  }

  public func activate() {
    switch backend {
    case .connection(let connection): connection.activate()
    case .session(let session): session.activate()
    }
  }

  public func cancel() {
    switch backend {
    case .connection(let connection): connection.activate(); connection.cancel()
    case .session(let session): session.cancel()
    }
  }

  public func sendAndForget(_ message: xpc_object_t) {
    switch backend {
    case .connection(let connection): connection.sendAndForget(message: XPCDictionary(message))
    case .session(let session): session.sendAndForget(message)
    }
  }

  public func send(_ message: xpc_object_t) async throws -> xpc_object_t {
    switch backend {
    case .connection(let connection): try await connection.send(message: XPCDictionary(message))
    case .session(let session): try await session.send(message)
    }
  }

}
