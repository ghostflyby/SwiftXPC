// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

// Extensions restoring the parts of the previous first-party container API
// that Apple's `XPCDictionary`/`XPCArray` do not (yet) provide. Accessors
// that Apple ships in later OS versions (`uuid_t`/`FileDescriptor` typed
// subscripts on macOS 27) are intentionally not mirrored here to avoid
// same-signature ambiguity once those become available.

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
        xpc_dictionary_apply(raw) { key, value in
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

extension XPCArray: @retroactive RandomAccessCollection, @retroactive MutableCollection {
  public typealias Element = xpc_object_t
  public typealias Indices = Range<Int>

  public var startIndex: Int { 0 }
  public var endIndex: Int { withUnsafeUnderlyingArray { Int(xpc_array_get_count($0)) } }

  /// Accesses the element at `position`. Like `Array`, an out-of-range index
  /// is a programming error and traps.
  public subscript(position: Int) -> xpc_object_t {
    get {
      withUnsafeUnderlyingArray { raw in
        precondition(
          position >= startIndex && position < endIndex, "XPCArray index out of range")
        return xpc_array_get_value(raw, position)
      }
    }
    set {
      withUnsafeUnderlyingArray { raw in
        precondition(
          position >= startIndex && position < endIndex, "XPCArray index out of range")
        xpc_array_set_value(raw, position, newValue)
      }
    }
  }
}

extension XPCArray: @retroactive @unchecked Sendable {}
