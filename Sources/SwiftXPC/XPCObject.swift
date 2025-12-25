// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

@frozen
public struct XPCObject: @unchecked Sendable, Equatable, Hashable {
  public let xpc_object: xpc_object_t

  package init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(xpc_hash(xpc_object))
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    return xpc_equal(lhs.xpc_object, rhs.xpc_object)
  }
}
