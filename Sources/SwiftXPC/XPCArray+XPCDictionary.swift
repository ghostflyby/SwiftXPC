import XPC

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

  private func validateIndex(_ position: Int) throws {
    guard position >= startIndex && position < endIndex else {
      throw XPCMarshalError.outOfBounds(index: position, count: count)
    }
  }

  public subscript(position: Int) -> XPCObject {
    get {
      try! validateIndex(position)
      let item = xpc_array_get_value(xpc_object, position)
      return .init(xpc_object: item)
    }
    set {
      try! validateIndex(position)
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

@frozen
public struct XPCDictionary: @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
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
  public init?(replyTo message: XPCDictionary) {
    if let reply = xpc_dictionary_create_reply(message.xpc_object) {
      self.xpc_object = reply
    } else {
      return nil
    }
  }

  public var connection: XPCConnection? {
    if let conn = xpc_dictionary_get_remote_connection(xpc_object) {
      return XPCConnection(xpc_object: conn)
    } else {
      return nil
    }
  }

  var keys: [String] {
    var result: [String] = []
    xpc_dictionary_apply(xpc_object) { key, _ in
      result.append(String(cString: key))
      return true
    }
    return result
  }

  func contains(key: String) -> Bool {
    xpc_dictionary_get_value(xpc_object, key) != nil
  }

  public init() {
    self.xpc_object = xpc_dictionary_create(nil, nil, 0)
  }
}

extension XPCDictionary {

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

}
