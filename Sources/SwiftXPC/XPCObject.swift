// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

@frozen
public struct XPCObject: @unchecked Sendable, Equatable, Hashable {
  public let xpc_object: xpc_object_t
  public func hash(into hasher: inout Hasher) {
    hasher.combine(xpc_hash(xpc_object))
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    return xpc_equal(lhs.xpc_object, rhs.xpc_object)
  }
}

@frozen
public struct XPCRichError: Error, @unchecked Sendable {

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
