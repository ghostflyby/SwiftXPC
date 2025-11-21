// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

public protocol XPCObject: Sendable, Equatable, Hashable {
  var xpc_object: xpc_object_t { get }
  init(xpc_object: xpc_object_t)
}

extension XPCObject {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    return xpc_equal(lhs.xpc_object, rhs.xpc_object)
  }

}

extension XPCObject where Self: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(xpc_hash(xpc_object))
  }
}

@frozen
public struct XPCObjectUnknown: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }
}

@frozen
public struct XPCRichError: XPCObject, Error, @unchecked Sendable {

  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_endpoint_t) {
    self.xpc_object = xpc_object
  }

  @available(macOS 14, *)
  var message: String {
    if let s = xpc_rich_error_copy_description(xpc_object) {
      String(cString: s)
    } else {
      ""
    }
  }

  @available(macOS 14, *)
  var canRetry: Bool { xpc_rich_error_can_retry(xpc_object) }

}
