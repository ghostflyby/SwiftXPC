// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
  import Foundation
  import XPC

  /// A protocol for types that can be marshaled to and from XPC objects.
  ///
  /// Conform standard types via `@XPCMarshal` (generates both witnesses for
  /// structs, enums, and final classes) or implement the requirements by
  /// hand. Distributed actors get actor-reference marshaling through
  /// `XPCExportableActor` instead.
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

  /// The only error type thrown by marshaling APIs. Equality is determined
  /// entirely by `kind`; construct via the static factories, which mirror
  /// the cases with better labels.
  @XPCMarshal
  public struct XPCMarshalError: Error, CustomStringConvertible, Sendable, Equatable, Hashable {
    @XPCMarshal
    public enum Kind: Sendable, Equatable, Hashable {
      case missingKey(String)
      case unknownEnumCase(String, enumName: String)
      case typeMismatch(expected: String, actual: String)
      case outOfBounds(index: Int, count: Int)
      case invalidActorReference(String)
      case remoteActorExportUnsupported(String)
      case actorResolutionFailed(String)
      case unsupportedProtocolVersion(expected: UInt64, actual: UInt64)
    }
    public let kind: Kind

    public init(kind: Kind) {
      self.kind = kind
    }

    public static func missingKey(_ key: String) -> Self {
      .init(kind: .missingKey(key))
    }

    public static func unknownEnumCase(_ name: String, enumName: String) -> Self {
      .init(kind: .unknownEnumCase(name, enumName: enumName))
    }

    public static func typeMismatch(expected: String, actual: String) -> Self {
      .init(kind: .typeMismatch(expected: expected, actual: actual))
    }

    public static func outOfBounds(index: Int, count: Int) -> Self {
      .init(kind: .outOfBounds(index: index, count: count))
    }

    public static func invalidActorReference(_ reason: String) -> Self {
      .init(kind: .invalidActorReference(reason))
    }

    public static func remoteActorExportUnsupported(_ actorType: String) -> Self {
      .init(kind: .remoteActorExportUnsupported(actorType))
    }

    public static func actorResolutionFailed(_ reason: String) -> Self {
      .init(kind: .actorResolutionFailed(reason))
    }

    public static func unsupportedProtocolVersion(expected: UInt64, actual: UInt64) -> Self {
      .init(kind: .unsupportedProtocolVersion(expected: expected, actual: actual))
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
      case .invalidActorReference(let reason):
        return "Invalid actor reference: \(reason)"
      case .remoteActorExportUnsupported(let actorType):
        return "Cannot export remote actor \(actorType)"
      case .actorResolutionFailed(let reason):
        return "Actor resolution failed: \(reason)"
      case .unsupportedProtocolVersion(let expected, let actual):
        return "Unsupported protocol version \(actual); expected \(expected)"
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

  extension Float: XPCMarshal {
    public func marshal() throws(XPCMarshalError) -> XPCObject {
      XPCObject(xpc_object: xpc_double_create(Double(self)))
    }
    public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
      try ensureType(object, is: XPC_TYPE_DOUBLE)
      return Float(xpc_double_get_value(object.xpc_object))
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
      var array = XPCArray()
      for item in self {
        array.append(try item.marshal())
      }
      return XPCObject(xpc_object: array.xpc_object)
    }

    public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
      try ensureType(object, is: XPC_TYPE_ARRAY)
      let raw = XPCArray(xpc_object: object.xpc_object)
      var array = [Element]()
      let count = raw.count
      array.reserveCapacity(count)
      for item in raw {
        let value = try Element.unmarshal(from: item)
        array.append(value)
      }
      return array
    }
  }

  extension Dictionary: XPCMarshal where Key == String, Value: XPCMarshal {
    public func marshal() throws(XPCMarshalError) -> XPCObject {
      var dict = XPCDictionary()
      for (k, v) in self {
        dict[k] = try v.marshal()
      }
      return XPCObject(xpc_object: dict.xpc_object)
    }

    public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> Self {
      try ensureType(object, is: XPC_TYPE_DICTIONARY)
      let xpcDict = XPCDictionary(xpc_object: object.xpc_object)
      var result: [String: Value] = [:]
      let count = xpcDict.keys.count
      result.reserveCapacity(count)
      for key in xpcDict.keys {
        if let valueObject = xpcDict[key] {
          let value = try Value.unmarshal(from: valueObject)
          result[key] = value
        }
      }
      return result
    }
  }

#endif
