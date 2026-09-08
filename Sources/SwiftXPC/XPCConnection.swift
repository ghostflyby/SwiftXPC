// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import XPC

public struct XPCConnection: @unchecked Sendable {
  internal let xpc_object: xpc_connection_t
  internal let _handlerState = _ConnectionHandlerState()

  package init(xpc_object: xpc_connection_t) {
    self.xpc_object = xpc_object
  }
}

final class _ConnectionHandlerState: @unchecked Sendable {
  var genericHandler: (@Sendable (XPCObject) -> Void)?
  var invalidationHandler: (@Sendable () -> Void)?
  var interruptionHandler: (@Sendable () -> Void)?
  var terminationImminentHandler: (@Sendable () -> Void)?
  var peerCodeSigningErrorHandler: (@Sendable () -> Void)?
}

/// Routes one connection event object to the matching dedicated handler.
/// Error objects whose dedicated handler was never registered fall through to
/// the generic handler, preserving pre-routing behavior for existing callers.
internal func routeConnectionEvent(
  _ state: _ConnectionHandlerState, _ object: XPCObject
) {
  let raw = object.xpc_object
  if xpc_equal(raw, XPC_ERROR_CONNECTION_INVALID) {
    state.invalidationHandler?()
    return
  }
  if xpc_equal(raw, XPC_ERROR_CONNECTION_INTERRUPTED) {
    state.interruptionHandler?()
    return
  }
  if xpc_equal(raw, XPC_ERROR_TERMINATION_IMMINENT) {
    if let handler = state.terminationImminentHandler {
      handler()
      return
    }
  }
  if #available(macOS 15.0, *),
    xpc_equal(raw, XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT),
    let handler = state.peerCodeSigningErrorHandler
  {
    handler()
    return
  }
  state.genericHandler?(object)
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

  public enum MachServiceFlag {
    case Listener
    case Privileged

  }

  public init(
    machServiceName: String, flags: MachServiceFlag, dispatchQueue: DispatchQueue? = nil
  ) {
    let flag =
      switch flags {
      case .Listener:
        XPC_CONNECTION_MACH_SERVICE_LISTENER
      case .Privileged:
        XPC_CONNECTION_MACH_SERVICE_PRIVILEGED
      }
    xpc_object = xpc_connection_create_mach_service(
      machServiceName, dispatchQueue, UInt64(flag))
  }

  public func set(targetQueue: DispatchQueue?) {
    xpc_connection_set_target_queue(xpc_object, targetQueue)
  }

}

extension XPCConnection {
  public func setEventHandler(handler: @escaping @Sendable (XPCObject) -> Void) {
    _handlerState.genericHandler = handler
    xpc_connection_set_event_handler(
      xpc_object,
      { [state = _handlerState] xpc_object in
        routeConnectionEvent(state, XPCObject(xpc_object: xpc_object))
      }
    )
  }
  /// Register a handler to run when the connection is invalidated.
  /// Multiple handlers are chained: the previous handler runs before the new one.
  public func addInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
    let previous = _handlerState.invalidationHandler
    _handlerState.invalidationHandler = {
      previous?()
      handler()
    }
  }

  /// Register a handler to run when the connection is interrupted.
  /// Multiple handlers are chained: the previous handler runs before the new one.
  public func addInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
    let previous = _handlerState.interruptionHandler
    _handlerState.interruptionHandler = {
      previous?()
      handler()
    }
  }

  /// Register a handler to run when launchd announces imminent service
  /// termination (`XPC_ERROR_TERMINATION_IMMINENT`). Delivered only to peer
  /// connections received through a listener or `xpcMain`; no further messages
  /// arrive afterwards.
  /// Multiple handlers are chained: the previous handler runs before the new one.
  public func addTerminationImminentHandler(_ handler: @escaping @Sendable () -> Void) {
    let previous = _handlerState.terminationImminentHandler
    _handlerState.terminationImminentHandler = {
      previous?()
      handler()
    }
  }

  /// Register a handler to run when the peer fails this connection's code
  /// signing requirement (`XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT`).
  /// Multiple handlers are chained: the previous handler runs before the new one.
  @available(macOS 15.0, *)
  public func addPeerCodeSigningErrorHandler(_ handler: @escaping @Sendable () -> Void) {
    let previous = _handlerState.peerCodeSigningErrorHandler
    _handlerState.peerCodeSigningErrorHandler = {
      previous?()
      handler()
    }
  }

}

public func xpcTransactionBegin() {
  xpc_transaction_begin()
}

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
  public enum ConnectionError: Error, Sendable {
    case invalid
    case interupted
  }

  public func sendAndForget(message: XPCDictionary) {
    xpc_connection_send_message(xpc_object, message.xpc_object)
  }

  public func send(barrier: @escaping () -> Void) {
    xpc_connection_send_barrier(xpc_object, barrier)
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
    if xpc_equal(r, XPC_ERROR_CONNECTION_INVALID) {
      throw ConnectionError.invalid
    } else if xpc_equal(r, XPC_ERROR_CONNECTION_INTERRUPTED) {
      throw ConnectionError.interupted
    } else {
      return XPCObject(xpc_object: r)
    }
  }

  @available(*, noasync)
  public func send(message: XPCDictionary, replyQueue: DispatchQueue? = nil) throws(ConnectionError)
    -> XPCObject
  {
    let r = xpc_connection_send_message_with_reply_sync(xpc_object, message.xpc_object)
    if xpc_equal(r, XPC_ERROR_CONNECTION_INVALID) {
      throw ConnectionError.invalid
    } else if xpc_equal(r, XPC_ERROR_CONNECTION_INTERRUPTED) {
      throw ConnectionError.interupted
    } else {
      return XPCObject(xpc_object: r)
    }
  }

}

extension XPCConnection {
  public func activate() {
    xpc_connection_activate(xpc_object)
  }

  public func resume() {
    xpc_connection_resume(xpc_object)
  }

  public func suspend() {
    xpc_connection_suspend(xpc_object)
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
  var name: String? {
    let cString = xpc_connection_get_name(xpc_object)
    if let cString = cString {
      return String(cString: cString)
    } else {
      return nil
    }
  }

  var euid: uid_t {
    return xpc_connection_get_euid(xpc_object)
  }

  var egitid: gid_t {
    return xpc_connection_get_egid(xpc_object)
  }

  var asid: au_asid_t {
    return xpc_connection_get_asid(xpc_object)
  }

}

@available(macOS 14.4, *)
extension XPCConnection {
  public func setPeerEntitlementExistsRequirement(_ entitlement: String) -> Bool {
    xpc_connection_set_peer_entitlement_exists_requirement(xpc_object, entitlement) == 0
  }

  private func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, object: xpc_object_t
  ) -> Bool {
    xpc_connection_set_peer_entitlement_matches_value_requirement(
      xpc_object, entitlement, object) == 0
  }

  public func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, value: Int64
  ) -> Bool {
    setPeerEntitlementMatchesValueRequirement(entitlement, object: xpc_int64_create(value))
  }
  public func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, value: Bool
  ) -> Bool {
    setPeerEntitlementMatchesValueRequirement(
      entitlement, object: value ? XPC_BOOL_TRUE : XPC_BOOL_FALSE)
  }
  public func setPeerEntitlementMatchesValueRequirement(
    _ entitlement: String, value: String
  ) -> Bool {
    setPeerEntitlementMatchesValueRequirement(entitlement, object: xpc_string_create(value))
  }

  private func setPeerLightweightCodeRequirement(_ requirement: XPCObject) -> Bool {
    xpc_connection_set_peer_lightweight_code_requirement(
      xpc_object, requirement.xpc_object) == 0
  }

  public func setPeerPlatformIdentityRequirement(_ signingIdentifier: String?) -> Bool {
    xpc_connection_set_peer_platform_identity_requirement(
      xpc_object, signingIdentifier) == 0
  }

  public func setPeerTeamIdentityRequirement(_ teamIdentifier: String?) -> Bool {
    xpc_connection_set_peer_team_identity_requirement(
      xpc_object, teamIdentifier) == 0
  }

  public func setPeerCodeSigningRequirement(_ requirement: String) -> Bool {
    xpc_connection_set_peer_code_signing_requirement(
      xpc_object, requirement) == 0
  }

}

extension XPCConnection {
  public func set<T: Sendable>(context: T?) {
    // Release previous context before overwriting, preventing leak on repeated calls.
    if let oldContextPtr = xpc_connection_get_context(xpc_object) {
      let unmanaged = Unmanaged<AnyObject>.fromOpaque(oldContextPtr)
      unmanaged.release()
    }
    let box = Box(context)
    xpc_connection_set_context(
      xpc_object,
      Unmanaged.passRetained(box).toOpaque()
    )
    xpc_connection_set_finalizer_f(xpc_object) { contextPtr in
      if let contextPtr = contextPtr {
        let unmanaged = Unmanaged<AnyObject>.fromOpaque(contextPtr)
        unmanaged.release()
      }
    }
  }

  public func getContext<T: Sendable>() -> T? {
    guard let contextPtr = xpc_connection_get_context(xpc_object) else {
      return nil
    }
    let unmanaged = Unmanaged<AnyObject>.fromOpaque(contextPtr)
    return (unmanaged.takeUnretainedValue() as? Box<T>)?.value
  }
}

private final class Box<T> where T: Sendable {
  let value: T
  init(_ value: consuming T) { self.value = value }
}

extension XPCConnection: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_endpoint_create(self.xpc_object))
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> XPCConnection {
    let type = xpc_get_type(object.xpc_object)
    guard type == XPC_TYPE_ENDPOINT else {
      throw typeMismatch(expected: XPC_TYPE_ENDPOINT, actual: type)
    }
    return XPCConnection(xpc_object: xpc_connection_create_from_endpoint(object.xpc_object))
  }
}
