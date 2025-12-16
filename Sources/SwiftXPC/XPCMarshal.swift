// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import XPC

/// A protocol for types that can be marshaled to and from XPC objects
public protocol XPCMarshal {
  /// Marshals the value into an XPC object.
  func marshal() throws -> any XPCObject
  /// Unmarshals a value from an XPC object.
  static func unmarshal(from object: any XPCObject) throws -> Self
}

@attached(
  extension, conformances: XPCMarshal,
  names: named(marshal), named(unmarshal(from:))
)
public macro XPCMarshal() = #externalMacro(module: "SwiftXPCMacros", type: "XPCMarshalMacro")

public enum XPCMarshalError: Error, CustomStringConvertible {
  case expectedDictionary(actual: String)
  case missingKey(String)

  public var description: String {
    switch self {
    case .expectedDictionary(let actual):
      return "Expected XPC dictionary but found \(actual)"
    case .missingKey(let key):
      return "Missing key \(key) in XPC dictionary"
    }
  }
}

extension FileHandle: XPCMarshal {
  public func marshal() throws(EncodingError) -> any XPCObject {
    let xpcObject = xpc_fd_create(self.fileDescriptor)!
    return XPCObjectUnknown(xpc_object: xpcObject)
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    let actual = xpc_get_type(object.xpc_object)
    guard actual == XPC_TYPE_FD else {
      throw typeMismatch(FileHandle.self, object, actual: actual)
    }
    return .init(fileDescriptor: xpc_fd_dup(object.xpc_object), closeOnDealloc: true)
  }
}

private func typeMismatch<T>(
  _: T.Type, _ object: any XPCObject, actual: xpc_type_t? = nil
) -> DecodingError {
  let actualDescription: String
  if let actual {
    actualDescription = String(describing: actual)
  } else {
    actualDescription = String(describing: type(of: object))
  }
  return DecodingError.typeMismatch(
    T.self,
    .init(codingPath: [], debugDescription: "Expected \(T.self) but found \(actualDescription)")
  )
}

private func ensureType(
  _ object: any XPCObject, is expected: xpc_type_t, for swiftType: Any.Type
) throws {
  let actual = xpc_get_type(object.xpc_object)
  if actual != expected {
    throw typeMismatch(swiftType, object, actual: actual)
  }
}

extension Bool: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    XPCObjectUnknown(xpc_object: self ? XPC_BOOL_TRUE : XPC_BOOL_FALSE)
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_BOOL, for: Bool.self)
    return xpc_bool_get_value(object.xpc_object)
  }
}

extension String: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    XPCObjectUnknown(xpc_object: xpc_string_create(self))
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_STRING, for: String.self)
    let cString = xpc_string_get_string_ptr(object.xpc_object)!
    return String(cString: cString)
  }
}

extension Double: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    XPCObjectUnknown(xpc_object: xpc_double_create(self))
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_DOUBLE, for: Double.self)
    return xpc_double_get_value(object.xpc_object)
  }
}

extension Int64: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    XPCObjectUnknown(xpc_object: xpc_int64_create(self))
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_INT64, for: Int64.self)
    return xpc_int64_get_value(object.xpc_object)
  }
}

extension UInt64: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    XPCObjectUnknown(xpc_object: xpc_uint64_create(self))
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_UINT64, for: UInt64.self)
    return xpc_uint64_get_value(object.xpc_object)
  }
}

extension Int: XPCMarshal {
  public func marshal() throws -> any XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    let v = try Int64.unmarshal(from: object)
    return Int(v)
  }
}

extension UInt: XPCMarshal {
  public func marshal() throws -> any XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    let v = try UInt64.unmarshal(from: object)
    return UInt(v)
  }
}

extension Int8: XPCMarshal {
  public func marshal() throws -> any XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    Self(try Int64.unmarshal(from: object))
  }
}

extension Int16: XPCMarshal {
  public func marshal() throws -> any XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    Self(try Int64.unmarshal(from: object))
  }
}

extension Int32: XPCMarshal {
  public func marshal() throws -> any XPCObject { try Int64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    Self(try Int64.unmarshal(from: object))
  }
}

extension UInt8: XPCMarshal {
  public func marshal() throws -> any XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    Self(try UInt64.unmarshal(from: object))
  }
}

extension UInt16: XPCMarshal {
  public func marshal() throws -> any XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    Self(try UInt64.unmarshal(from: object))
  }
}

extension UInt32: XPCMarshal {
  public func marshal() throws -> any XPCObject { try UInt64(self).marshal() }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    Self(try UInt64.unmarshal(from: object))
  }
}

extension Data: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    return XPCObjectUnknown(
      xpc_object: self.withUnsafeBytes { buffer in
        xpc_data_create(buffer.baseAddress, buffer.count)
      })
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_DATA, for: Data.self)
    let length = xpc_data_get_length(object.xpc_object)
    let pointer = xpc_data_get_bytes_ptr(object.xpc_object)!
    return Data(bytes: pointer, count: length)
  }
}

extension Date: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    let seconds = Int64(timeIntervalSince1970)
    return XPCObjectUnknown(xpc_object: xpc_date_create(seconds))
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_DATE, for: Date.self)
    let seconds = xpc_date_get_value(object.xpc_object)
    return Date(timeIntervalSince1970: Double(seconds))
  }
}

extension UUID: XPCMarshal {

  public func marshal() throws -> any XPCObject {
    var uuid = uuid
    return XPCObjectUnknown(xpc_object: xpc_uuid_create(&uuid))
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_UUID, for: UUID.self)
    let bytes = xpc_uuid_get_bytes(object.xpc_object)
    return
      (bytes?.withMemoryRebound(to: uuid_t.self, capacity: 1) { ptr in
        UUID(uuid: ptr.pointee)
      })!
  }
}

extension Optional: XPCMarshal where Wrapped: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    switch self {
    case .some(let wrapped):
      return try wrapped.marshal()
    case .none:
      return XPCObjectUnknown(xpc_object: xpc_null_create())
    }
  }

  public static func unmarshal(from object: any XPCObject) throws -> Wrapped? {
    if xpc_get_type(object.xpc_object) == XPC_TYPE_NULL { return nil }
    return try Wrapped.unmarshal(from: object)
  }
}

extension Array: XPCMarshal where Element: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    let array = xpc_array_create_empty()
    for item in self {
      xpc_array_append_value(array, try item.marshal().xpc_object)
    }
    return XPCObjectUnknown(xpc_object: array)
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_ARRAY, for: [Element].self)
    let raw = object.xpc_object
    var array = [Element]()
    let count = xpc_array_get_count(raw)
    array.reserveCapacity(count)
    xpc_array_apply(raw) { i, v in
      let item = try! Element.unmarshal(from: XPCObjectUnknown(xpc_object: v))
      array.append(item)
      return true
    }
    return array
  }
}

extension Dictionary: XPCMarshal where Key == String, Value: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    let dict = xpc_dictionary_create_empty()
    for (k, v) in self {
      xpc_dictionary_set_value(dict, k, try v.marshal().xpc_object)
    }
    return XPCObjectUnknown(xpc_object: dict)
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    try ensureType(object, is: XPC_TYPE_DICTIONARY, for: [String: Value].self)
    let xpcDict = XPCObjectUnknown(xpc_object: object.xpc_object)
    var result: [String: Value] = [:]
    let count = xpc_dictionary_get_count(xpcDict.xpc_object)
    result.reserveCapacity(count)
    xpc_dictionary_apply(xpcDict.xpc_object) { k, v in
      let key = String(cString: k)
      let value = try! Value.unmarshal(from: XPCObjectUnknown(xpc_object: v))
      result[key] = value
      return true
    }
    return result
  }
}
