// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// A handle to an XPC connection: the named or anonymous channel over which
/// dictionaries travel between processes.
///
/// Configure handlers before `activate()`; after activation the connection
/// delivers events through those handlers. Errors arrive as dedicated
/// signals (`addInvalidationHandler`, `addInterruptionHandler`,
/// `addTerminationImminentHandler`, `addPeerCodeSigningErrorHandler`) rather
/// than as generic events.
public struct XPCConnection: @unchecked Sendable {
  internal let xpc_object: xpc_connection_t
  internal let _handlerState = _ConnectionHandlerState()

  package init(xpc_object: xpc_connection_t) {
    self.xpc_object = xpc_object
  }
}

/// Per-connection event handler storage. Thread-safe: XPC delivers events on
/// the connection's target queue while handlers may be chained from any
/// queue, so all access is lock-protected. Handlers should be installed
/// before `activate()`; later additions take effect for subsequent events.
final class _ConnectionHandlerState: @unchecked Sendable {
  struct Handlers {
    var generic: (@Sendable (XPCObject) -> Void)?
    var invalidation: (@Sendable () -> Void)?
    var interruption: (@Sendable () -> Void)?
    var terminationImminent: (@Sendable () -> Void)?
    var peerCodeSigningError: (@Sendable () -> Void)?
  }

  private let lock = NSLock()
  private var handlers = Handlers()

  private func withHandlers<T>(_ body: (inout Handlers) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&handlers)
  }

  func setGenericHandler(_ handler: @escaping @Sendable (XPCObject) -> Void) {
    withHandlers { $0.generic = handler }
  }

  func chain(
    _ keyPath: WritableKeyPath<Handlers, (@Sendable () -> Void)?>,
    _ handler: @escaping @Sendable () -> Void
  ) {
    withHandlers { state in
      let previous = state[keyPath: keyPath]
      state[keyPath: keyPath] = {
        previous?()
        handler()
      }
    }
  }

  /// Routes one connection event object to the matching dedicated handler.
  /// Invalidation and interruption events are always consumed by their
  /// dedicated chain (even when empty, matching historical behavior);
  /// termination-imminent and peer-code-signing errors fall through to the
  /// generic handler when their dedicated handler was never registered.
  func route(_ object: XPCObject) {
    let snapshot = withHandlers { $0 }
    let raw = object.xpc_object
    if xpc_equal(raw, XPC_ERROR_CONNECTION_INVALID) {
      snapshot.invalidation?()
      return
    }
    if xpc_equal(raw, XPC_ERROR_CONNECTION_INTERRUPTED) {
      snapshot.interruption?()
      return
    }
    if xpc_equal(raw, XPC_ERROR_TERMINATION_IMMINENT) {
      if let handler = snapshot.terminationImminent {
        handler()
        return
      }
    }
    if #available(macOS 15.0, *),
      xpc_equal(raw, XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT),
      let handler = snapshot.peerCodeSigningError
    {
      handler()
      return
    }
    snapshot.generic?(object)
  }
}

extension XPCConnection {
  /// True when the wrapped XPC object is a connection, not an error object
  /// delivered by the event handler (e.g. connection invalid/interrupted).
  package var isConnectionObject: Bool {
    xpc_get_type(xpc_object) == XPC_TYPE_CONNECTION
  }
}

extension XPCConnection {
  public init(name: String?, dispatchQueue: DispatchQueue? = nil) {
    xpc_object = xpc_connection_create(name, dispatchQueue)
  }

  /// Creation options for a named mach service connection. Mirrors the C
  /// flags, which are combinable.
  public struct MachServiceOptions: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Advertise the name as a listener this process serves.
    public static let listener = MachServiceOptions(rawValue: 1 << 0)
    /// Request privileged (root) access semantics for the name.
    public static let privileged = MachServiceOptions(rawValue: 1 << 1)
  }

  public init(
    machServiceName: String, options: MachServiceOptions = [], dispatchQueue: DispatchQueue? = nil
  ) {
    xpc_object = xpc_connection_create_mach_service(
      machServiceName, dispatchQueue, options.rawValue)
  }

  public func setTargetQueue(_ queue: DispatchQueue?) {
    xpc_connection_set_target_queue(xpc_object, queue)
  }

}

extension XPCConnection {
  public func setEventHandler(_ handler: @escaping @Sendable (XPCObject) -> Void) {
    _handlerState.setGenericHandler(handler)
    xpc_connection_set_event_handler(
      xpc_object,
      { [state = _handlerState] xpc_object in
        state.route(XPCObject(xpc_object: xpc_object))
      }
    )
  }
  /// Register a handler to run when the connection is invalidated.
  /// Multiple handlers are chained: the previous handler runs before the new one.
  public func addInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
    _handlerState.chain(\.invalidation, handler)
  }

  /// Register a handler to run when the connection is interrupted.
  /// Multiple handlers are chained: the previous handler runs before the new one.
  public func addInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
    _handlerState.chain(\.interruption, handler)
  }

  /// Register a handler to run when launchd announces imminent service
  /// termination (`XPC_ERROR_TERMINATION_IMMINENT`). Delivered only to peer
  /// connections received through a listener or `xpcMain`; no further messages
  /// arrive afterwards.
  /// Multiple handlers are chained: the previous handler runs before the new one.
  public func addTerminationImminentHandler(_ handler: @escaping @Sendable () -> Void) {
    _handlerState.chain(\.terminationImminent, handler)
  }

  /// Register a handler to run when the peer fails this connection's code
  /// signing requirement (`XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT`).
  /// Multiple handlers are chained: the previous handler runs before the new one.
  @available(macOS 15.0, *)
  public func addPeerCodeSigningErrorHandler(_ handler: @escaping @Sendable () -> Void) {
    _handlerState.chain(\.peerCodeSigningError, handler)
  }

}

/// Signals to launchd that this process is busy. While a transaction is
/// open the service is not considered idle-eligible. (C: xpc_transaction_begin)
public func xpcTransactionBegin() {
  xpc_transaction_begin()
}

/// Signals that a previously opened transaction finished. (C: xpc_transaction_end)
public func xpcTransactionEnd() {
  xpc_transaction_end()
}

extension XPCConnection {

  @available(macOS 12.0, *)
  public var invalidationReason: String? {
    if let s = xpc_connection_copy_invalidation_reason(xpc_object) {
      String(cString: s)
    } else {
      nil
    }
  }
}

extension XPCConnection {
  /// The reason an asynchronous send failed. A named service connection may
  /// recover from `.interrupted` on a later send (launchd relaunches the
  /// service); `.invalid` and `.peerCodeSigningRequirement` are terminal,
  /// though retries may still cover brief cold-start or registration gaps.
  public enum ConnectionError: Error, Sendable {
    case invalid
    case interrupted
    /// The peer failed this connection's code signing requirement
    /// (`XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT`); XPC delivers the error
    /// through the reply path as well, so sends surface it here.
    case peerCodeSigningRequirement
  }

  public func sendAndForget(message: XPCDictionary) {
    xpc_connection_send_message(xpc_object, message.xpc_object)
  }

  private static func connectionError(forReply raw: xpc_object_t) -> ConnectionError? {
    if xpc_equal(raw, XPC_ERROR_CONNECTION_INVALID) {
      return .invalid
    }
    if xpc_equal(raw, XPC_ERROR_CONNECTION_INTERRUPTED) {
      return .interrupted
    }
    if #available(macOS 15.0, *),
      xpc_equal(raw, XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT)
    {
      // Gated at 15 to match the installer (`setPeerCodeSigningRequirement`):
      // requirements can only be installed on macOS 15+, so earlier replies
      // can never carry this error.
      return .peerCodeSigningRequirement
    }
    return nil
  }

  public func send(message: XPCDictionary, replyQueue: DispatchQueue? = nil)
    async throws(ConnectionError)
    -> XPCObject
  {
    let r = await withCheckedContinuation { continuation in
      xpc_connection_send_message_with_reply(
        xpc_object,
        message.xpc_object,
        replyQueue,
        { xpc_object in
          continuation.resume(returning: XPCObject(xpc_object: xpc_object))
        }
      )
    }.xpc_object
    if let error = Self.connectionError(forReply: r) {
      throw error
    }
    return XPCObject(xpc_object: r)
  }

  @available(*, noasync)
  public func send(message: XPCDictionary, replyQueue: DispatchQueue? = nil)
    throws(ConnectionError)
    -> XPCObject
  {
    let r = xpc_connection_send_message_with_reply_sync(xpc_object, message.xpc_object)
    if let error = Self.connectionError(forReply: r) {
      throw error
    }
    return XPCObject(xpc_object: r)
  }

}

extension XPCConnection {
  public func activate() {
    xpc_connection_activate(xpc_object)
  }

  public func cancel() {
    xpc_connection_cancel(xpc_object)
  }

}

extension XPCConnection {
  /// The process identifier of the peer, or a value without meaning if the
  /// connection has no peer yet. Primary input for peer validation.
  public var pid: pid_t {
    xpc_connection_get_pid(xpc_object)
  }
}

extension XPCConnection: CustomDebugStringConvertible {
  public var debugDescription: String {
    let cString = xpc_copy_description(xpc_object)
    defer { free(cString) }
    return String(cString: cString)
  }
}

extension XPCConnection {
  /// The service name the connection was created with, or nil for anonymous
  /// and received connections.
  public var name: String? {
    let cString = xpc_connection_get_name(xpc_object)
    if let cString = cString {
      return String(cString: cString)
    } else {
      return nil
    }
  }

  /// Effective user ID of the peer.
  public var euid: uid_t {
    xpc_connection_get_euid(xpc_object)
  }

  /// Effective group ID of the peer.
  public var egid: gid_t {
    xpc_connection_get_egid(xpc_object)
  }

  /// Audit session ID of the peer.
  public var asid: au_asid_t {
    xpc_connection_get_asid(xpc_object)
  }

}

@available(macOS 14.4, *)
extension XPCConnection {
  /// The reason a peer requirement could not be installed on this connection.
  public struct PeerRequirementError: Error, Sendable {
    /// The raw status returned by XPC (errno-style, e.g. `ENOTSUP` on
    /// platforms without code signing requirement support).
    public let status: Int32
  }

  private func checkPeerRequirementStatus(
    _ status: Int32
  ) throws(PeerRequirementError) {
    if status != 0 {
      throw PeerRequirementError(status: status)
    }
  }

  public func setPeerCodeSigningRequirement(
    _ requirement: String
  ) throws(PeerRequirementError) {
    try checkPeerRequirementStatus(
      xpc_connection_set_peer_code_signing_requirement(xpc_object, requirement))
  }

  public func setPeerEntitlementExistsRequirement(
    _ entitlement: String
  ) throws(PeerRequirementError) {
    try checkPeerRequirementStatus(
      xpc_connection_set_peer_entitlement_exists_requirement(xpc_object, entitlement))
  }

  private func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, object: xpc_object_t
  ) throws(PeerRequirementError) {
    try checkPeerRequirementStatus(
      xpc_connection_set_peer_entitlement_matches_value_requirement(
        xpc_object, entitlement, object))
  }

  public func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, value: Int64
  ) throws(PeerRequirementError) {
    try setPeerEntitlementMatchesValueRequirement(
      entitlement, object: xpc_int64_create(value))
  }

  public func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, value: Bool
  ) throws(PeerRequirementError) {
    try setPeerEntitlementMatchesValueRequirement(
      entitlement, object: value ? XPC_BOOL_TRUE : XPC_BOOL_FALSE)
  }

  public func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, value: String
  ) throws(PeerRequirementError) {
    try setPeerEntitlementMatchesValueRequirement(
      entitlement, object: xpc_string_create(value))
  }

  private func setPeerLightweightCodeRequirement(
    _ requirement: XPCObject
  ) throws(PeerRequirementError) {
    try checkPeerRequirementStatus(
      xpc_connection_set_peer_lightweight_code_requirement(
        xpc_object, requirement.xpc_object))
  }

  public func setPeerPlatformIdentityRequirement(
    _ signingIdentifier: String?
  ) throws(PeerRequirementError) {
    try checkPeerRequirementStatus(
      xpc_connection_set_peer_platform_identity_requirement(xpc_object, signingIdentifier))
  }

  public func setPeerTeamIdentityRequirement(
    _ teamIdentifier: String?
  ) throws(PeerRequirementError) {
    try checkPeerRequirementStatus(
      xpc_connection_set_peer_team_identity_requirement(xpc_object, teamIdentifier))
  }
}

extension XPCConnection: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_endpoint_create(xpc_object))
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> XPCConnection {
    let type = xpc_get_type(object.xpc_object)
    guard type == XPC_TYPE_ENDPOINT else {
      throw typeMismatch(expected: XPC_TYPE_ENDPOINT, actual: type)
    }
    return XPCConnection(xpc_object: xpc_connection_create_from_endpoint(object.xpc_object))
  }
}
