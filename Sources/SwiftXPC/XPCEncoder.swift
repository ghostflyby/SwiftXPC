// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import XPC

public struct XPCEncoder {
  public init() {}

  public func encode<T: Encodable>(_ value: T) throws -> any XPCObject {
    let encoder = _XPCEncoder()
    try value.encode(to: encoder)
    if let encodingError = encoder.error {
      throw encodingError
    }
    if let storage = encoder.storage {
      return storage
    } else {
      return XPCNull()
    }
  }
}

final class _XPCEncoder: Encoder {
  var storage: XPCValue?
  var error: EncodingError?

  var codingPath: [CodingKey] = []
  var userInfo: [CodingUserInfoKey: Any] = [:]

  private func recordContainerTypeMismatch(expected: String) {
    guard error == nil else { return }
    let invalidValue: Any = storage ?? XPCNull()
    error = EncodingError.invalidValue(
      invalidValue,
      EncodingError.Context(
        codingPath: codingPath,
        debugDescription:
          "Attempted to get \(expected) encoding container when storage is \(storageDescription)"
      )
    )
  }

  private var storageDescription: String {
    guard let storage else { return "unset" }
    return storage.containerKindDescription
  }

  func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key>
  where Key: CodingKey {
    if storage == nil {
      let dict = XPCDictionary()
      storage = .Dictionary(dict)
    }
    guard case .Dictionary(let dict) = storage else {
      recordContainerTypeMismatch(expected: "keyed")
      let dict = XPCDictionary()
      storage = .Dictionary(dict)
      let container = XPCKeyedEncodingContainer<Key>(
        dictionary: dict,
        codingPath: codingPath
      )
      return KeyedEncodingContainer(container)
    }
    let container = XPCKeyedEncodingContainer<Key>(
      dictionary: dict,
      codingPath: codingPath
    )
    return KeyedEncodingContainer(container)
  }

  func unkeyedContainer() -> UnkeyedEncodingContainer {
    if storage == nil {
      storage = .Array(XPCArray())
    }

    guard case .Array(let array) = storage else {
      recordContainerTypeMismatch(expected: "unkeyed")
      let array = XPCArray()
      storage = .Array(array)
      return XPCUnkeyedEncodingContainer(
        array: array,
        codingPath: codingPath
      )
    }
    return XPCUnkeyedEncodingContainer(
      array: array,
      codingPath: codingPath
    )
  }

  func singleValueContainer() -> SingleValueEncodingContainer {
    return XPCSingleValueEncodingContainer(encoder: self)
  }
  func singleValueContainer() -> XPCSingleValueEncodingContainer {
    return XPCSingleValueEncodingContainer(encoder: self)
  }
}

private struct XPCKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  typealias Key = Key

  var dictionary: XPCDictionary
  var codingPath: [CodingKey]

  init(dictionary: XPCDictionary, codingPath: [CodingKey]) {
    self.dictionary = dictionary
    self.codingPath = codingPath
  }

  private mutating func set(_ obj: any XPCObject, for key: Key) {
    dictionary[key.stringValue] = obj
  }

  mutating func encodeNil(forKey key: Key) throws {
    set(XPCNull(), for: key)
  }

  mutating func encode(_ value: Bool, forKey key: Key) throws {
    set(XPCBool(value), for: key)
  }

  mutating func encode(_ value: String, forKey key: Key) throws {
    set(XPCString(value), for: key)
  }

  mutating func encode(_ value: Double, forKey key: Key) throws {
    set(XPCDouble(value), for: key)
  }

  mutating func encode(_ value: Float, forKey key: Key) throws {
    set(XPCDouble(Double(value)), for: key)
  }

  mutating func encode(_ value: Int, forKey key: Key) throws {
    try encode(Int64(value), forKey: key)
  }
  mutating func encode(_ value: Int8, forKey key: Key) throws {
    try encode(Int64(value), forKey: key)
  }
  mutating func encode(_ value: Int16, forKey key: Key) throws {
    try encode(Int64(value), forKey: key)
  }
  mutating func encode(_ value: Int32, forKey key: Key) throws {
    try encode(Int64(value), forKey: key)
  }
  mutating func encode(_ value: Int64, forKey key: Key) throws {
    set(XPCInt64(value), for: key)
  }

  mutating func encode(_ value: UInt, forKey key: Key) throws {
    try encode(UInt64(value), forKey: key)
  }
  mutating func encode(_ value: UInt8, forKey key: Key) throws {
    try encode(UInt64(value), forKey: key)
  }
  mutating func encode(_ value: UInt16, forKey key: Key) throws {
    try encode(UInt64(value), forKey: key)
  }
  mutating func encode(_ value: UInt32, forKey key: Key) throws {
    try encode(UInt64(value), forKey: key)
  }
  mutating func encode(_ value: UInt64, forKey key: Key) throws {
    set(XPCUInt64(value), for: key)
  }

  mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
    if value is any XPCObject {
      let obj = value as! any XPCObject
      set(obj, for: key)
      return
    }
    if value is any XPCMarshal {
      let xpcCodable = value as! any XPCBaseMarshal
      let obj = try xpcCodable.marshal()
      set(obj, for: key)
      return
    }
    let subEncoder = _XPCEncoder()
    subEncoder.codingPath = codingPath + [key]
    try value.encode(to: subEncoder)
    let value = subEncoder.storage!
    let obj = XPCObjectUnknown(xpc_object: value.xpc_object)
    set(obj, for: key)
  }

  mutating func encode<Wrapped>(_ value: XPC<Wrapped>, forKey key: Key) throws {
    set(try value.wrappedValue.marshal(), for: key)
  }

  mutating func nestedContainer<NestedKey>(
    keyedBy keyType: NestedKey.Type,
    forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
    let dict = XPCDictionary()
    set(dict, for: key)
    let container = XPCKeyedEncodingContainer<NestedKey>(
      dictionary: dict,
      codingPath: codingPath + [key]
    )
    return KeyedEncodingContainer(container)
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
    let array = XPCArray()
    set(array, for: key)
    return XPCUnkeyedEncodingContainer(
      array: array,
      codingPath: codingPath + [key]
    )

  }

  mutating func superEncoder() -> Encoder {
    return _XPCEncoder()
  }

  mutating func superEncoder(forKey key: Key) -> Encoder {
    return _XPCEncoder()
  }
}

private struct XPCUnkeyedEncodingContainer: UnkeyedEncodingContainer {
  var array: XPCArray
  var codingPath: [CodingKey]
  var count: Int = 0

  private mutating func append(_ obj: any XPCObject) {
    array.append(obj)
    count += 1
  }

  mutating func encodeNil() throws {
    append(XPCNull())
  }

  mutating func encode(_ value: Bool) throws {
    append(XPCBool(value))
  }

  mutating func encode(_ value: String) throws {
    append(XPCString(value))
  }

  mutating func encode(_ value: Double) throws {
    append(XPCDouble(value))
  }

  mutating func encode(_ value: Float) throws {
    append(XPCDouble(Double(value)))
  }

  mutating func encode(_ value: Int) throws { try encode(Int64(value)) }
  mutating func encode(_ value: Int8) throws { try encode(Int64(value)) }
  mutating func encode(_ value: Int16) throws { try encode(Int64(value)) }
  mutating func encode(_ value: Int32) throws { try encode(Int64(value)) }
  mutating func encode(_ value: Int64) throws { append(XPCInt64(value)) }

  mutating func encode(_ value: UInt) throws { try encode(Int(value)) }
  mutating func encode(_ value: UInt8) throws { try encode(Int(value)) }
  mutating func encode(_ value: UInt16) throws { try encode(Int(value)) }
  mutating func encode(_ value: UInt32) throws { try encode(Int(value)) }
  mutating func encode(_ value: UInt64) throws { append(XPCUInt64(value)) }

  mutating func encode<T>(_ value: T) throws where T: Encodable {
    if value is any XPCObject {
      let obj = value as! any XPCObject
      append(obj)
      return
    }
    if value is any XPCMarshal {
      let xpcCodable = value as! any XPCBaseMarshal
      let obj = try xpcCodable.marshal()
      append(obj)
      return
    }
    let subEncoder = _XPCEncoder()
    subEncoder.codingPath = codingPath
    try value.encode(to: subEncoder)
    append(subEncoder.storage ?? XPCNull())
  }

  mutating func nestedContainer<NestedKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
    let dict = XPCDictionary()
    append(dict)
    let container = XPCKeyedEncodingContainer<NestedKey>(
      dictionary: dict,
      codingPath: codingPath
    )
    return KeyedEncodingContainer(container)
  }

  mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
    let arr = XPCArray()
    append(arr)
    return XPCUnkeyedEncodingContainer(
      array: arr,
      codingPath: codingPath
    )
  }

  mutating func superEncoder() -> Encoder {
    return _XPCEncoder()
  }
}

struct XPCSingleValueEncodingContainer: SingleValueEncodingContainer {
  let encoder: _XPCEncoder
  var codingPath: [CodingKey] { encoder.codingPath }

  private mutating func set(_ obj: any XPCObject) {
    encoder.storage = XPCValue(obj.xpc_object)
  }

  mutating func encodeNil() throws {
    set(XPCNull())
  }

  mutating func encode(_ value: Bool) throws {
    set(XPCBool(value))
  }

  mutating func encode(_ value: String) throws {
    set(XPCString(value))
  }

  mutating func encode(_ value: Double) throws {
    set(XPCDouble(value))
  }

  mutating func encode(_ value: Float) throws {
    set(XPCDouble(Double(value)))
  }

  mutating func encode(_ value: Int) throws { try encode(Int64(value)) }
  mutating func encode(_ value: Int8) throws { try encode(Int(value)) }
  mutating func encode(_ value: Int16) throws { try encode(Int(value)) }
  mutating func encode(_ value: Int32) throws { try encode(Int(value)) }
  mutating func encode(_ value: Int64) throws { set(XPCInt64(value)) }

  mutating func encode(_ value: UInt) throws { try encode(UInt64(value)) }
  mutating func encode(_ value: UInt8) throws { try encode(UInt64(value)) }
  mutating func encode(_ value: UInt16) throws { try encode(UInt64(value)) }
  mutating func encode(_ value: UInt32) throws { try encode(UInt64(value)) }
  mutating func encode(_ value: UInt64) throws { set(XPCUInt64(value)) }

  mutating func encode<T>(_ value: T) throws where T: Encodable {
    if value is any XPCObject {
      let obj = value as! any XPCObject
      set(obj)
      return
    }
    if value is any XPCMarshal {
      let xpcCodable = value as! any XPCBaseMarshal
      let obj = try xpcCodable.marshal()
      set(obj)
      return
    }
    let subEncoder = _XPCEncoder()
    subEncoder.codingPath = codingPath
    try value.encode(to: subEncoder)
    set(subEncoder.storage ?? XPCNull())
  }

  mutating func encode<Wrapped>(_ value: XPC<Wrapped>) throws {
    set(try value.wrappedValue.marshal())
  }
}

extension XPCValue {
  fileprivate var containerKindDescription: String {
    switch self {
    case .Bool: return "bool"
    case .Data: return "data"
    case .Double: return "double"
    case .Int64: return "int64"
    case .UInt64: return "uint64"
    case .String: return "string"
    case .FileDescriptor: return "file descriptor"
    case .Date: return "date"
    case .UUID: return "uuid"
    case .SharedMemory: return "shared memory"
    case .Null: return "null"
    case .Activity: return "activity"
    case .Connection: return "connection"
    case .Endpoint: return "endpoint"
    case .Dictionary: return "dictionary"
    case .Array: return "array"
    case .RichError: return "rich error"
    }
  }
}
