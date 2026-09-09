// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
  import Foundation
  import XPC

  /// A non-owning wrapper around a raw XPC object, the vocabulary type every
  /// marshaling API exchanges. Use `XPCMarshal` conformances to convert between
  /// Swift values and XPC objects; use `xpc_object` only to interoperate with
  /// the C API directly.
  @frozen
  public struct XPCObject: @unchecked Sendable, Equatable, Hashable {
    public let xpc_object: xpc_object_t

    /// Wraps a raw XPC object without retaining it. The wrapper is a
    /// non-owning view: lifetime remains governed by XPC's own reference
    /// counting on the underlying object graph.
    public init(xpc_object: xpc_object_t) {
      self.xpc_object = xpc_object
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(xpc_hash(xpc_object))
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
      return xpc_equal(lhs.xpc_object, rhs.xpc_object)
    }
  }

  extension XPCObject: XPCMarshal {
    public func marshal() throws(XPCMarshalError) -> XPCObject {
      self
    }

    public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> XPCObject {
      object
    }
  }

  extension XPCObject: CustomDebugStringConvertible {
    public var debugDescription: String {
      let cString = xpc_copy_description(xpc_object)
      defer { free(cString) }
      return String(cString: cString)
    }
  }
#endif
