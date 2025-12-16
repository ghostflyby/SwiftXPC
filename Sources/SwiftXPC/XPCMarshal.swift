// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation

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
  case expectedDictionary(actual: XPCValue)
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
    return XPCFileHandle(self)
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .FileDescriptor(let xpcFileHandle) = XPCValue(xpc_object: object.xpc_object)
    else {
      throw DecodingError.typeMismatch(
        FileHandle.self,
        DecodingError.Context(
          codingPath: [],
          debugDescription: "Expected XPCFileHandle but found \(type(of: object))"
        )
      )
    }
    return Self.init(fileDescriptor: xpcFileHandle.fileDescriptor, closeOnDealloc: true)
  }
}

private func typeMismatch<T>(_: T.Type, _ object: any XPCObject) -> DecodingError {
  DecodingError.typeMismatch(
    T.self,
    .init(codingPath: [], debugDescription: "Expected \(T.self) but found \(type(of: object))")
  )
}

extension Bool: XPCMarshal {
  public func marshal() throws -> any XPCObject { XPCBool(self) }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Bool(let v) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch(Bool.self, object)
    }
    return v.rawValue
  }
}

extension String: XPCMarshal {
  public func marshal() throws -> any XPCObject { XPCString(self) }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .String(let v) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch(String.self, object)
    }
    return v.rawValue
  }
}

extension Double: XPCMarshal {
  public func marshal() throws -> any XPCObject { XPCDouble(self) }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Double(let v) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch(Double.self, object)
    }
    return v.rawValue
  }
}

extension Int64: XPCMarshal {
  public func marshal() throws -> any XPCObject { XPCInt64(self) }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Int64(let v) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch(Int64.self, object)
    }
    return v.rawValue
  }
}

extension UInt64: XPCMarshal {
  public func marshal() throws -> any XPCObject { XPCUInt64(self) }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .UInt64(let v) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch(UInt64.self, object)
    }
    return v.rawValue
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
    return XPCData(self)
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Data(let xpcData) = XPCValue(xpc_object: object.xpc_object)
    else {
      throw typeMismatch(Data.self, object)
    }
    return xpcData.rawValue
  }
}

extension Date: XPCMarshal {
  public func marshal() throws -> any XPCObject { XPCDate(self) }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Date(let xpcDate) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch(Date.self, object)
    }
    return xpcDate.rawValue
  }
}

extension UUID: XPCMarshal {

  public func marshal() throws -> any XPCObject {
    return XPCUUID(self)
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .UUID(let xpcUUID) = XPCValue(xpc_object: object.xpc_object)
    else {
      throw typeMismatch(UUID.self, object)
    }
    return xpcUUID.rawValue
  }
}

extension Optional: XPCMarshal where Wrapped: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    switch self {
    case .some(let wrapped):
      return try wrapped.marshal()
    case .none:
      return XPCNull()
    }
  }

  public static func unmarshal(from object: any XPCObject) throws -> Wrapped? {
    let value = XPCValue(xpc_object: object.xpc_object)
    if case .Null = value { return nil }
    return try Wrapped.unmarshal(from: object)
  }
}

extension Array: XPCMarshal where Element: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    var array = XPCArray()
    for item in self {
      array.append(try item.marshal())
    }
    return array
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Array(let xpcArray) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch([Element].self, object)
    }
    return try (0..<xpcArray.count).map { index in
      let raw: XPCValue = xpcArray[index]
      return try Element.unmarshal(from: raw)
    }
  }
}

extension Dictionary: XPCMarshal where Key == String, Value: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    var dict = XPCDictionary()
    for (k, v) in self {
      dict[k] = try v.marshal()
    }
    return dict
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Dictionary(let xpcDict) = XPCValue(xpc_object: object.xpc_object) else {
      throw typeMismatch([String: Value].self, object)
    }
    var result: [String: Value] = [:]
    for key in xpcDict.keys {
      if let raw: XPCValue = xpcDict[key] {
        result[key] = try Value.unmarshal(from: raw)
      }
    }
    return result
  }
}
