// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import XPC

/// A protocol for types that can be marshaled to and from XPC objects
public protocol XPCMarshal {
  /// Marshals the value into an XPC object.
  func marshal() throws(XPCMarshalError) -> XPCObject
  /// Unmarshals a value from an XPC object.
  static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self
}

@attached(
  extension, conformances: XPCMarshal,
  names: named(marshal), named(unmarshal(from:))
)
public macro XPCMarshal() = #externalMacro(module: "SwiftXPCMacros", type: "XPCMarshalMacro")

@XPCMarshal
public struct XPCMarshalError: Error, CustomStringConvertible, Sendable, Equatable, Hashable {
  @XPCMarshal
  public enum Kind: Sendable, Equatable, Hashable {
    case missingKey(String)
    case unknownEnumCase(String, enumName: String)
    case typeMismatch(expected: String, actual: String)
    case outOfBounds(index: Int, count: Int)
  }
  public let kind: Kind
  public let file: String
  public let line: UInt
  public let function: String

  public static func missingKey(
    _ key: String, file: String = #file, line: UInt = #line, function: String = #function
  ) -> Self {
    .init(kind: .missingKey(key), file: file, line: line, function: function)
  }

  public static func unknownEnumCase(
    _ name: String, enumName: String, file: String = #file, line: UInt = #line,
    function: String = #function
  ) -> Self {
    .init(
      kind: .unknownEnumCase(name, enumName: enumName), file: file, line: line, function: function)
  }

  public static func typeMismatch(
    expected: String, actual: String, file: String = #file, line: UInt = #line,
    function: String = #function
  ) -> Self {
    .init(
      kind: .typeMismatch(expected: expected, actual: actual), file: file, line: line,
      function: function)
  }

  public static func outOfBounds(
    index: Int, count: Int, file: String = #file, line: UInt = #line, function: String = #function
  ) -> Self {
    .init(
      kind: .outOfBounds(index: index, count: count), file: file, line: line, function: function)
  }

  public var description: String {
    switch self.kind {
    case .missingKey(let key):
      return "Missing key \(key) in XPC dictionary"
    case .unknownEnumCase(let name, let enumName):
      return "Unknown case \(name) for enum \(enumName)"
    case .typeMismatch(let expected, let actual):
      return "Expected \(expected) but found \(actual)"
    case .outOfBounds(let index, let count):
      return "Index \(index) out of bounds for array of count \(count)"
    }
  }
}

extension FileHandle: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    let xpcObject = xpc_fd_create(self.fileDescriptor)!
    return XPCObject(xpc_object: xpcObject)
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    let actual = xpc_get_type(object.xpc_object)
    guard actual == XPC_TYPE_FD else {
      throw typeMismatch(expected: XPC_TYPE_FD, actual: actual)
    }
    return .init(fileDescriptor: xpc_fd_dup(object.xpc_object), closeOnDealloc: true)
  }
}

func typeMismatch(
  expected: xpc_type_t, actual: xpc_type_t
) -> XPCMarshalError {
  let expectedDescription = String(cString: xpc_type_get_name(expected))
  let actualDescription = String(cString: xpc_type_get_name(actual))
  return .typeMismatch(expected: expectedDescription, actual: actualDescription)
}

func ensureType(
  _ object: XPCObject, is expected: xpc_type_t
) throws(XPCMarshalError) {
  let actual = xpc_get_type(object.xpc_object)
  if actual != expected {
    throw typeMismatch(expected: expected, actual: actual)
  }
}

extension Bool: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: self ? XPC_BOOL_TRUE : XPC_BOOL_FALSE)
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_BOOL)
    return xpc_bool_get_value(object.xpc_object)
  }
}

extension String: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_string_create(self))
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_STRING)
    let cString = xpc_string_get_string_ptr(object.xpc_object)!
    return String(cString: cString)
  }
}

extension Double: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_double_create(self))
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_DOUBLE)
    return xpc_double_get_value(object.xpc_object)
  }
}

extension Int64: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_int64_create(self))
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_INT64)
    return xpc_int64_get_value(object.xpc_object)
  }
}

extension UInt64: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    XPCObject(xpc_object: xpc_uint64_create(self))
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_UINT64)
    return xpc_uint64_get_value(object.xpc_object)
  }
}

extension Int: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    let v = try Int64.unmarshal(from: object)
    return Int(v)
  }
}

extension UInt: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    let v = try UInt64.unmarshal(from: object)
    return UInt(v)
  }
}

extension Int8: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    Self(try Int64.unmarshal(from: object))
  }
}

extension Int16: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    Self(try Int64.unmarshal(from: object))
  }
}

extension Int32: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    Self(try Int64.unmarshal(from: object))
  }
}

extension UInt8: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    Self(try UInt64.unmarshal(from: object))
  }
}

extension UInt16: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    Self(try UInt64.unmarshal(from: object))
  }
}

extension UInt32: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    Self(try UInt64.unmarshal(from: object))
  }
}

extension Data: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    return XPCObject(
      xpc_object: self.withUnsafeBytes { buffer in
        xpc_data_create(buffer.baseAddress, buffer.count)
      })
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_DATA)
    let length = xpc_data_get_length(object.xpc_object)
    let pointer = xpc_data_get_bytes_ptr(object.xpc_object)!
    return Data(bytes: pointer, count: length)
  }
}

extension Date: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    return try self.timeIntervalSince1970.marshal()
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    return try Date(timeIntervalSince1970: Double.unmarshal(from: object))
  }
}

extension UUID: XPCMarshal {

  public func marshal() throws(XPCMarshalError) -> XPCObject {
    var uuid = uuid
    return XPCObject(xpc_object: xpc_uuid_create(&uuid))
  }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_UUID)
    let bytes = xpc_uuid_get_bytes(object.xpc_object)
    return
      (bytes?.withMemoryRebound(to: uuid_t.self, capacity: 1) { ptr in
        UUID(uuid: ptr.pointee)
      })!
  }
}

extension Optional: XPCMarshal where Wrapped: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    switch self {
    case .some(let wrapped):
      return try wrapped.marshal()
    case .none:
      return XPCObject(xpc_object: xpc_null_create())
    }
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Wrapped? {
    if xpc_get_type(object.xpc_object) == XPC_TYPE_NULL { return nil }
    return try Wrapped.unmarshal(from: object)
  }
}

extension Array: XPCMarshal where Element: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    let array = xpc_array_create_empty()
    for item in self {
      xpc_array_append_value(array, try item.marshal().xpc_object)
    }
    return XPCObject(xpc_object: array)
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_ARRAY)
    let raw = object.xpc_object
    var array = [Element]()
    let count = xpc_array_get_count(raw)
    array.reserveCapacity(count)
    xpc_array_apply(raw) { i, v in
      let item = try! Element.unmarshal(from: XPCObject(xpc_object: v))
      array.append(item)
      return true
    }
    return array
  }
}

extension Dictionary: XPCMarshal where Key == String, Value: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    let dict = xpc_dictionary_create_empty()
    for (k, v) in self {
      xpc_dictionary_set_value(dict, k, try v.marshal().xpc_object)
    }
    return XPCObject(xpc_object: dict)
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
    try ensureType(object, is: XPC_TYPE_DICTIONARY)
    let xpcDict = XPCObject(xpc_object: object.xpc_object)
    var result: [String: Value] = [:]
    let count = xpc_dictionary_get_count(xpcDict.xpc_object)
    result.reserveCapacity(count)
    xpc_dictionary_apply(xpcDict.xpc_object) { k, v in
      let key = String(cString: k)
      let value = try! Value.unmarshal(from: XPCObject(xpc_object: v))
      result[key] = value
      return true
    }
    return result
  }
}
