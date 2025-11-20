// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

@frozen
public struct XPCConnection: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_connection_t
  public init(xpc_object: xpc_connection_t) {
    self.xpc_object = xpc_object
  }
}

extension XPCConnection {
  public init(name: String?, dispatchQueue: DispatchQueue? = nil) {
    xpc_object = xpc_connection_create(name, dispatchQueue)
  }

  public init(endpoint: XPCEndpoint, dispatchQueue: DispatchQueue? = nil) {
    xpc_object = xpc_connection_create_from_endpoint(endpoint.xpc_object)
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
  public func setEventHandler(handler: @escaping @Sendable (XPCValue) -> Void) {
    xpc_connection_set_event_handler(
      xpc_object,
      { xpc_object in
        let obj = XPCValue(xpc_object)
        handler(obj)
      }
    )
  }
}

@MainActor
private var mainHandler: @Sendable (XPCConnection) -> Void = { _ in }

@MainActor
private func m(_ c: xpc_connection_t) {
  let connection = XPCConnection(xpc_object: c)
  mainHandler(connection)
}

@MainActor
public func xpcMain(_ handler: @escaping @Sendable (_ connection: XPCConnection) -> Void) -> Never {
  mainHandler = handler
  xpc_main { c in m(c) }
}

public func xpcTransactionBegin() {
  xpc_transaction_begin()
}

public func xpcTransactionEnd() {
  xpc_transaction_end()
}

extension XPCConnection {
  public var invalidationReason: String? {
    if let s = xpc_connection_copy_invalidation_reason(xpc_object) {
      String(cString: s)
    } else {
      nil
    }
  }
}

extension XPCConnection {
  public func send(message: XPCValue) {
    xpc_connection_send_message(xpc_object, message.xpc_object)
  }
  public func send(message: any XPCObject) {
    xpc_connection_send_message(xpc_object, message.xpc_object)
  }

  public func send(barrier: @escaping () -> Void) {
    xpc_connection_send_barrier(xpc_object, barrier)
  }

  public func send(message: XPCDictionary, replyQueue: DispatchQueue? = nil) async -> XPCValue {
    await withCheckedContinuation { continuation in
      xpc_connection_send_message_with_reply(
        xpc_object,
        message.xpc_object,
        replyQueue,
        { xpc_object in
          let obj = XPCValue(xpc_object)
          continuation.resume(returning: obj)
        }
      )
    }
  }

  public func send(message: XPCDictionary, replyQueue: DispatchQueue? = nil) -> XPCValue {
    XPCValue(xpc_connection_send_message_with_reply_sync(xpc_object, message.xpc_object))
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

@frozen
public struct XPCEndpoint: XPCObject, @unchecked Sendable {

  public let xpc_object: xpc_endpoint_t

  public init(xpc_object: xpc_endpoint_t) {
    self.xpc_object = xpc_object
  }

  public init(name: XPCConnection) {
    xpc_object = xpc_endpoint_create(name.xpc_object)
  }

}
