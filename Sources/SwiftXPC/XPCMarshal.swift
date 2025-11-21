// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A protocol for types that can be marshaled to and from XPC objects.
///
/// * Implement `XPCMarshal` manually for types that can be directly marshaled.
/// * Implement `XPCMarshalCodable` for types that can be marshaled using Codable.
///
/// DO NOT implement both
public protocol XPCBaseMarshal: ~Copyable {
  /// Marshals the value into an XPC object.
  func marshal() throws -> any XPCObject
  /// Unmarshals a value from an XPC object.
  static func unmarshal(from object: any XPCObject) throws -> Self
}

public protocol XPCMarshal: XPCBaseMarshal {}

public protocol XPCMarshalCodable: Codable, XPCBaseMarshal {}

extension XPCBaseMarshal where Self: XPCMarshalCodable {
  public func marshal() throws -> any XPCObject {
    return try XPCEncoder().encode(self)
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    let decoder = XPCDecoder()
    return try decoder.decode(Self.self, from: object)
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

extension Int: XPCMarshalCodable {}
extension UInt: XPCMarshalCodable {}
extension Int8: XPCMarshalCodable {}
extension Int16: XPCMarshalCodable {}
extension Int32: XPCMarshalCodable {}
extension Int64: XPCMarshalCodable {}
extension UInt8: XPCMarshalCodable {}
extension UInt16: XPCMarshalCodable {}
extension UInt32: XPCMarshalCodable {}
extension UInt64: XPCMarshalCodable {}
extension String: XPCMarshalCodable {}
extension Bool: XPCMarshalCodable {}
extension Double: XPCMarshalCodable {}

extension Data: XPCMarshal {
  public func marshal() throws -> any XPCObject {
    return XPCData(self)
  }

  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .Data(let xpcData) = XPCValue(xpc_object: object.xpc_object)
    else {
      throw DecodingError.typeMismatch(
        Data.self,
        DecodingError.Context(
          codingPath: [],
          debugDescription: "Expected XPCData but found \(type(of: object))"
        )
      )
    }
    return xpcData.rawValue
  }
}

extension Date: XPCMarshalCodable {}

extension UUID: XPCMarshal {

  public func marshal() throws -> any XPCObject {
    return XPCUUID(self)
  }
  public static func unmarshal(from object: any XPCObject) throws -> Self {
    guard case .UUID(let xpcUUID) = XPCValue(xpc_object: object.xpc_object)
    else {
      throw DecodingError.typeMismatch(
        UUID.self,
        DecodingError.Context(
          codingPath: [],
          debugDescription: "Expected XPCUUID but found \(type(of: object))"
        )
      )
    }
    return xpcUUID.rawValue
  }
}

extension Array: XPCBaseMarshal, XPCMarshalCodable where Self: Codable {}

extension Dictionary: XPCBaseMarshal, XPCMarshalCodable where Self: Codable {}
extension Optional: XPCBaseMarshal, XPCMarshalCodable where Self: Codable {}

@propertyWrapper
public struct XPC<Wrapped: XPCBaseMarshal>: XPCMarshalCodable {
  public func encode(to encoder: any Encoder) throws {
    guard let xpcEncoder = encoder as? _XPCEncoder else {
      throw EncodingError.invalidValue(
        self,
        EncodingError.Context(
          codingPath: encoder.codingPath,
          debugDescription: "Expected XPCEncoder but found \(type(of: encoder))"
        )
      )
    }
    var single = xpcEncoder.singleValueContainer() as XPCSingleValueEncodingContainer
    try single.encode(self)
  }

  public init(from decoder: any Decoder) throws {
    guard let xpcDecoder = decoder as? _XPCDecoder else {
      throw DecodingError.typeMismatch(
        XPC<Wrapped>.self,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Expected XPCDecoder but found \(type(of: decoder))"
        )
      )
    }
    let single = try xpcDecoder.singleValueContainer() as XPCSingleValueDecodingContainer
    self.wrappedValue = try single.decode(XPC<Wrapped>.self).wrappedValue
  }

  public var wrappedValue: Wrapped

  public init(wrappedValue: Wrapped) {
    self.wrappedValue = wrappedValue
  }

}
