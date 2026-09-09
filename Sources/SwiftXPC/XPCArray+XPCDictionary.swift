import XPC

/// An ordered collection of XPC objects with *handle semantics*: copies
/// share the underlying XPC array, so mutations through any copy are
/// visible through all of them.
@frozen
public struct XPCArray: @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }
}

extension XPCArray: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_object)
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_ARRAY)
    return XPCArray(xpc_object: object.xpc_object)
  }
}

extension XPCArray: RandomAccessCollection {

  public var startIndex: Int {
    0
  }

  public var endIndex: Int {
    Int(xpc_array_get_count(xpc_object))
  }

  public var count: Int {
    endIndex
  }

}

extension XPCArray: MutableCollection {
  public typealias Element = XPCObject

  /// Accesses the element at `position`. Like `Array`, an out-of-range index
  /// is a programming error and traps.
  public subscript(position: Int) -> XPCObject {
    get {
      precondition(position >= startIndex && position < endIndex, "XPCArray index out of range")
      let item = xpc_array_get_value(xpc_object, position)
      return .init(xpc_object: item)
    }
    set {
      precondition(position >= startIndex && position < endIndex, "XPCArray index out of range")
      xpc_array_set_value(xpc_object, position, newValue.xpc_object)
    }
  }

}

extension XPCArray {
  public mutating func append(_ obj: XPCObject) {
    xpc_array_append_value(xpc_object, obj.xpc_object)
  }
}

extension XPCArray {
  public init() {
    self.init(xpc_object: xpc_array_create_empty())
  }
}

/// A dictionary mapping string keys to XPC objects.
///
/// `XPCDictionary` has *handle semantics*: copying a value shares the
/// underlying XPC object, so mutations through any copy are visible through
/// all of them. This differs from `Dictionary` value semantics and matches
/// libxpc's own object model.
@frozen
public struct XPCDictionary: @unchecked Sendable {
  public let xpc_object: xpc_object_t

  /// Wraps a raw XPC dictionary object without retaining it.
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

  /// Creates an empty dictionary.
  public init() {
    self.xpc_object = xpc_dictionary_create(nil, nil, 0)
  }
}

extension XPCDictionary: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_object)
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_DICTIONARY)
    return XPCDictionary(xpc_object: object.xpc_object)
  }
}

extension XPCDictionary {
  /// Creates a reply dictionary addressed back to the sender of `message`.
  /// Returns nil when `message` does not expect a reply.
  public init?(replyTo message: XPCDictionary) {
    if let reply = xpc_dictionary_create_reply(message.xpc_object) {
      self.xpc_object = reply
    } else {
      return nil
    }
  }

  /// The connection the message was received on, if this dictionary was
  /// extracted from an incoming message.
  public var remoteConnection: XPCConnection? {
    if let conn = xpc_dictionary_get_remote_connection(xpc_object) {
      return XPCConnection(xpc_object: conn)
    } else {
      return nil
    }
  }

  /// All keys present in the dictionary, in XPC's iteration order.
  public var keys: [String] {
    var result: [String] = []
    xpc_dictionary_apply(xpc_object) { key, _ in
      result.append(String(cString: key))
      return true
    }
    return result
  }

  /// Number of entries in the dictionary.
  public var count: Int {
    xpc_dictionary_get_count(xpc_object)
  }

  func contains(key: String) -> Bool {
    xpc_dictionary_get_value(xpc_object, key) != nil
  }
}

extension XPCDictionary: Sequence {
  /// An iterator over `(key, value)` pairs.
  public struct Iterator: IteratorProtocol {
    private var remaining: [(key: String, value: XPCObject)]

    init(dictionary: XPCDictionary) {
      var items: [(key: String, value: XPCObject)] = []
      xpc_dictionary_apply(dictionary.xpc_object) { key, value in
        items.append((String(cString: key), XPCObject(xpc_object: value)))
        return true
      }
      self.remaining = items
    }

    public mutating func next() -> (key: String, value: XPCObject)? {
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

extension XPCDictionary {

  /// Accesses the value stored under `key`.
  ///
  /// Assigning `nil` stores an explicit XPC null under the key (it does *not*
  /// remove the entry); use `removeValue(forKey:)` to delete. This mirrors
  /// XPC's own model where "absent" and "present-but-null" are distinct, and
  /// keeps optional encoding lossless.
  public subscript(key: String) -> XPCObject? {
    get {
      if let item = xpc_dictionary_get_value(xpc_object, key) {
        .init(xpc_object: item)
      } else {
        nil
      }
    }
    set {
      if let newValue = newValue {
        xpc_dictionary_set_value(xpc_object, key, newValue.xpc_object)
      } else {
        xpc_dictionary_set_value(xpc_object, key, xpc_null_create())
      }
    }
  }

  /// Removes the entry under `key`.
  public func removeValue(forKey key: String) {
    xpc_dictionary_set_value(xpc_object, key, nil)
  }

}
