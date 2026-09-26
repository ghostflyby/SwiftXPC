// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

// Extensions restoring the parts of the previous first-party container API
// that Apple's `XPCDictionary`/`XPCArray` do not (yet) provide. Accessors
// that Apple ships in later OS versions (`uuid_t`/`FileDescriptor` typed
// subscripts on macOS 27) are intentionally not mirrored here to avoid
// same-signature ambiguity once those become available.

/// Asserts what libxpc guarantees for raw handles: XPC objects are
/// immutable after creation and safe to use from any thread, so a handle may
/// cross isolation boundaries even though the type itself is not `Sendable`.
package struct SendableXPCObject: @unchecked Sendable {
  package let raw: xpc_object_t
  package init(_ raw: xpc_object_t) {
    self.raw = raw
  }
}

extension SendableXPCObject: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> xpc_object_t {
    raw
  }
  public static func unmarshal(from object: xpc_object_t) throws(XPCMarshalError) -> Self {
    Self(object)
  }
}

extension XPCDictionary: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> xpc_object_t {
    xpcObject
  }
  public static func unmarshal(from object: xpc_object_t) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_DICTIONARY)
    return Self(object)
  }
}

extension XPCArray: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> xpc_object_t {
    xpcObject
  }
  public static func unmarshal(from object: xpc_object_t) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_ARRAY)
    return Self(object)
  }
}

extension XPCDictionary {
  /// Handle-style access to the underlying XPC object. The wrapper is a
  /// non-owning view: lifetime remains governed by ARC on the underlying
  /// object graph.
  public var xpcObject: xpc_object_t {
    withUnsafeUnderlyingDictionary { $0 }
  }

  /// Creates a reply dictionary addressed back to the sender of `message`.
  /// Returns nil when `message` does not expect a reply.
  public init?(replyTo message: XPCDictionary) {
    guard let reply = xpc_dictionary_create_reply(message.xpcObject) else {
      return nil
    }
    self.init(reply)
  }

  /// The connection the message was received on, if this dictionary was
  /// extracted from an incoming message.
  public var remoteConnection: XPCConnection? {
    xpc_dictionary_get_remote_connection(xpcObject).map(XPCConnection.init)
  }

  func contains(key: String) -> Bool {
    xpc_dictionary_get_value(xpcObject, key) != nil
  }
}

extension XPCDictionary: @retroactive Sequence {
  public typealias Element = (key: String, value: xpc_object_t)

  /// An iterator over `(key, value)` pairs.
  public struct Iterator: IteratorProtocol {
    private var remaining: [Element]

    init(dictionary: XPCDictionary) {
      var items: [Element] = []
      dictionary.withUnsafeUnderlyingDictionary { raw in
        _ = xpc_dictionary_apply(raw) { key, value in
          items.append((String(cString: key), value))
          return true
        }
      }
      self.remaining = items
    }

    public mutating func next() -> Element? {
      remaining.isEmpty ? nil : remaining.removeFirst()
    }
  }

  /// Iterates a snapshot of all `(key, value)` pairs in XPC's iteration
  /// order. The values are non-owning views: finish iterating (and use the
  /// pairs) while the dictionary is alive.
  public func makeIterator() -> Iterator {
    Iterator(dictionary: self)
  }
}

extension XPCDictionary: @retroactive @unchecked Sendable {}

extension XPCArray {
  /// Handle-style access to the underlying XPC object (non-owning view).
  public var xpcObject: xpc_object_t {
    withUnsafeUnderlyingArray { $0 }
  }

  /// Appends an object. The array retains the object, mirroring
  /// `xpc_array_append_value`.
  public mutating func append(_ object: xpc_object_t) {
    withUnsafeUnderlyingArray { xpc_array_append_value($0, object) }
  }
}

extension XPCArray: @retroactive Sequence {
  public typealias Element = xpc_object_t

  /// An iterator over elements in XPC's storage order. The values are
  /// non-owning views: finish iterating while the array is alive.
  public struct Iterator: IteratorProtocol {
    private let array: XPCArray
    private var index = 0

    init(array: XPCArray) {
      self.array = array
    }

    public mutating func next() -> xpc_object_t? {
      let current = index
      guard current < array.count else { return nil }
      index += 1
      return array.withUnsafeUnderlyingArray { xpc_array_get_value($0, current) }
    }
  }

  public func makeIterator() -> Iterator {
    Iterator(array: self)
  }
}

extension XPCArray: @retroactive @unchecked Sendable {}
