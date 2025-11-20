// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import XPC

public struct XPCDecoder {
  public init() {}

  public func decode<T: Decodable>(_ type: T.Type, from root: XPCValue) throws -> T {
    let decoder = _XPCDecoder(root: root)
    return try T(from: decoder)
  }

  public func decode<T: Decodable>(_ type: T.Type, from root: any XPCObject) throws -> T {
    let decoder = _XPCDecoder(root: XPCValue(xpc_object: root.xpc_object))
    return try T(from: decoder)
  }

  func decode(_ type: XPCEndpoint.Type, from root: XPCValue) throws -> XPCEndpoint {
    guard case .Endpoint(let value) = root else {
      throw DecodingError.typeMismatch(
        XPCEndpoint.self,
        .init(codingPath: [], debugDescription: "Expected endpoint", )
      )
    }
    return value
  }

  func decode<T: FileHandle>(_ type: T.Type, from root: XPCValue) throws -> T {
    guard case .FileDescriptor(let value) = root else {
      throw DecodingError.typeMismatch(
        FileHandle.self,
        .init(codingPath: [], debugDescription: "Expected file descriptor", )
      )
    }
    return value.asFileHandle(type: T.self)
  }

  func decode(_ type: UnsafeMutableRawBufferPointer.Type, from root: XPCValue) throws
    -> UnsafeMutableRawBufferPointer
  {
    guard case .SharedMemory(let value) = root else {
      throw DecodingError.typeMismatch(
        UnsafeMutableRawBufferPointer.self,
        .init(codingPath: [], debugDescription: "Expected shared memory", )
      )
    }
    return value.rawValue
  }
}

class _XPCDecoder: Decoder {
  let root: XPCValue

  var codingPath: [CodingKey] = []

  var userInfo: [CodingUserInfoKey: Any] = [:]

  init(root: XPCValue) {
    self.root = root
  }

  func container<Key>(keyedBy type: Key.Type) throws(DecodingError) -> KeyedDecodingContainer<Key>
  where Key: CodingKey {
    guard case .Dictionary(let dictionary) = root else {
      throw DecodingError.typeMismatch(
        XPCDictionary.self,
        .init(codingPath: codingPath, debugDescription: "Expected dictionary", )
      )
    }
    let container = XPCKeyedDecodingContainer<Key>(
      dictionary: dictionary,
      codingPath: codingPath
    )
    return KeyedDecodingContainer(container)
  }

  func unkeyedContainer() throws -> UnkeyedDecodingContainer {
    guard case .Array(let array) = root else {
      throw DecodingError.typeMismatch(
        [XPCArray].self,
        .init(codingPath: codingPath, debugDescription: "Expected array", )
      )
    }
    return XPCUnkeyedDecodingContainer(
      array: array,
      codingPath: codingPath
    )
  }

  func singleValueContainer() throws -> SingleValueDecodingContainer {
    return XPCSingleValueDecodingContainer(decoder: self)
  }
  func singleValueContainer() throws -> XPCSingleValueDecodingContainer {
    return XPCSingleValueDecodingContainer(decoder: self)
  }
}

private struct XPCKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  typealias Key = Key

  let dictionary: XPCDictionary
  var codingPath: [CodingKey]

  init(dictionary: XPCDictionary, codingPath: [CodingKey]) {
    self.dictionary = dictionary
    self.codingPath = codingPath
  }

  var allKeys: [Key] {
    dictionary.keys.map { Key(stringValue: $0) }.compactMap { $0 }
  }

  func contains(_ key: Key) -> Bool {
    dictionary.contains(key: key.stringValue)
  }

  func decodeNil(forKey key: Key) throws -> Bool {
    if case .Null = raw(for: key) {
      return true
    }
    return false
  }

  private func raw(for key: Key) -> XPCValue? {
    dictionary[key.stringValue]
  }

  private func throwTypeMismatch<T>(_ type: T.Type, forKey key: Key) throws -> Never {
    throw DecodingError.typeMismatch(
      type,
      .init(
        codingPath: codingPath + [key],
        debugDescription: "Expected XPC type \(type)", )
    )
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
    if case .Bool(let value) = raw(for: key) {
      return value.rawValue
    }
    try throwTypeMismatch(XPCBool.self, forKey: key)
  }

  func decode(_ type: String.Type, forKey key: Key) throws -> String {
    if case .String(let value) = raw(for: key) {
      return value.rawValue
    }
    try throwTypeMismatch(XPCString.self, forKey: key)
  }

  func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
    if case .Double(let value) = raw(for: key) {
      return value.rawValue
    }
    try throwTypeMismatch(XPCDouble.self, forKey: key)
  }

  func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
    return Float(try decode(Double.self, forKey: key))
  }

  func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
    Int(try decode(Int64.self, forKey: key))
  }

  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
    Int8(try decode(Int64.self, forKey: key))
  }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
    Int16(try decode(Int64.self, forKey: key))
  }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
    Int32(try decode(Int64.self, forKey: key))
  }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
    if case .Int64(let value) = raw(for: key) {
      return value.rawValue
    }
    try throwTypeMismatch(XPCInt64.self, forKey: key)
  }

  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
    UInt(try decode(UInt64.self, forKey: key))
  }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
    UInt8(try decode(UInt64.self, forKey: key))
  }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
    UInt16(try decode(UInt64.self, forKey: key))
  }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
    UInt32(try decode(UInt64.self, forKey: key))
  }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
    if case .UInt64(let value) = raw(for: key) {
      return value.rawValue
    }
    try throwTypeMismatch(XPCUInt64.self, forKey: key)
  }

  func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
    guard let v = raw(for: key) else {
      throw DecodingError.keyNotFound(
        key,
        .init(
          codingPath: codingPath + [key],
          debugDescription: "Key not found for nested value", )
      )
    }
    if let ct = type as? any XPCObject.Type {
      let obj = ct.init(xpc_object: v.xpc_object)
      return obj as! T
    }
    if let ct = type as? any XPCMarshal.Type {
      return try ct.unmarshal(from: v) as! T
    }

    let sub = _XPCDecoder(root: v)
    sub.codingPath = codingPath + [key]
    return try T(from: sub)
  }

  func nestedContainer<NestedKey>(
    keyedBy keyType: NestedKey.Type,
    forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
    guard case .Dictionary(let v) = raw(for: key) else {
      try throwTypeMismatch(XPCDictionary.self, forKey: key)
    }
    let container = XPCKeyedDecodingContainer<NestedKey>(
      dictionary: v,
      codingPath: codingPath + [key]
    )
    return KeyedDecodingContainer(container)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
    guard case .Array(let v) = raw(for: key) else {
      try throwTypeMismatch(XPCArray.self, forKey: key)
    }
    return XPCUnkeyedDecodingContainer(
      array: v,
      codingPath: codingPath + [key]
    )
  }

  func superDecoder() throws -> Decoder {
    let d = _XPCDecoder(root: .Null(XPCNull()))
    d.codingPath = codingPath
    return d
  }

  func superDecoder(forKey key: Key) throws -> Decoder {
    let v = raw(for: key) ?? .Null(XPCNull())
    let d = _XPCDecoder(root: v)
    d.codingPath = codingPath + [key]
    return d
  }
}

private struct XPCUnkeyedDecodingContainer: UnkeyedDecodingContainer {
  let array: XPCArray
  var codingPath: [CodingKey]
  var currentIndex: Int = 0

  var count: Int? {
    return array.count
  }

  var isAtEnd: Bool {
    return currentIndex >= (count ?? 0)
  }

  mutating func decodeNil() throws -> Bool {
    if case .Null = array[currentIndex] {
      currentIndex += 1
      return true
    }
    return false
  }

  private func throwTypeMismatch<T>(_ type: T.Type) throws -> Never {
    throw DecodingError.typeMismatch(
      type,
      .init(
        codingPath: codingPath + [AnyCodingKey(intValue: currentIndex)],
        debugDescription: "Expected XPC type \(type)", )
    )
  }

  mutating func decode(_ type: Bool.Type) throws -> Bool {
    if case .Bool(let value) = array[currentIndex] {
      currentIndex += 1
      return value.rawValue
    }
    try throwTypeMismatch(XPCBool.self)
  }

  mutating func decode(_ type: String.Type) throws -> String {
    if case .String(let value) = array[currentIndex] {
      currentIndex += 1
      return value.rawValue
    }
    try throwTypeMismatch(XPCString.self)
  }

  mutating func decode(_ type: Double.Type) throws -> Double {
    if case .Double(let value) = array[currentIndex] {
      currentIndex += 1
      return value.rawValue
    }
    try throwTypeMismatch(XPCDouble.self)
  }

  mutating func decode(_ type: Float.Type) throws -> Float {
    return Float(try decode(Double.self))
  }

  mutating func decode(_ type: Int.Type) throws -> Int { Int(try decode(Int64.self)) }
  mutating func decode(_ type: Int8.Type) throws -> Int8 { Int8(try decode(Int.self)) }
  mutating func decode(_ type: Int16.Type) throws -> Int16 { Int16(try decode(Int.self)) }
  mutating func decode(_ type: Int32.Type) throws -> Int32 { Int32(try decode(Int.self)) }
  mutating func decode(_ type: Int64.Type) throws -> Int64 {
    if case .Int64(let value) = array[currentIndex] {
      currentIndex += 1
      return value.rawValue
    }
    try throwTypeMismatch(XPCInt64.self)
  }

  mutating func decode(_ type: UInt.Type) throws -> UInt { UInt(try decode(Int.self)) }
  mutating func decode(_ type: UInt8.Type) throws -> UInt8 { UInt8(try decode(Int.self)) }
  mutating func decode(_ type: UInt16.Type) throws -> UInt16 { UInt16(try decode(Int.self)) }
  mutating func decode(_ type: UInt32.Type) throws -> UInt32 { UInt32(try decode(Int.self)) }
  mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
    if case .UInt64(let value) = array[currentIndex] {
      currentIndex += 1
      return value.rawValue
    }
    try throwTypeMismatch(XPCUInt64.self)
  }

  mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
    if let ct = type as? any XPCObject.Type {
      let obj = ct.init(xpc_object: array[currentIndex].xpc_object)
      currentIndex += 1
      return obj as! T
    }
    if let ct = type as? any XPCMarshal.Type {
      let o: XPCValue = array[currentIndex]
      currentIndex += 1
      return try ct.unmarshal(from: o) as! T
    }
    let dict: XPCValue = array[currentIndex]
    currentIndex += 1
    let sub = _XPCDecoder(root: dict)
    sub.codingPath = codingPath + [AnyCodingKey(intValue: currentIndex - 1)]
    return try T(from: sub)
  }

  mutating func nestedContainer<NestedKey>(
    keyedBy keyType: NestedKey.Type
  ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
    guard case .Dictionary(let v) = array[currentIndex] else {
      try throwTypeMismatch(XPCDictionary.self)
    }
    currentIndex += 1
    let container = XPCKeyedDecodingContainer<NestedKey>(
      dictionary: v,
      codingPath: codingPath + [AnyCodingKey(intValue: currentIndex - 1)]
    )
    return KeyedDecodingContainer(container)
  }

  mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
    guard case .Array(let v) = array[currentIndex] else {
      try throwTypeMismatch(XPCArray.self)
    }
    currentIndex += 1
    return XPCUnkeyedDecodingContainer(
      array: v,
      codingPath: codingPath + [AnyCodingKey(intValue: currentIndex - 1)]
    )
  }

  mutating func superDecoder() throws -> Decoder {
    let d = _XPCDecoder(root: .Null(XPCNull()))
    d.codingPath = codingPath
    return d
  }
}

struct XPCSingleValueDecodingContainer: SingleValueDecodingContainer {
  let decoder: _XPCDecoder
  var codingPath: [CodingKey] { decoder.codingPath }

  private var root: XPCValue { decoder.root }

  func decodeNil() -> Bool {
    if case .Null = root {
      return true
    }
    return false
  }

  func decode(_ type: Bool.Type) throws -> Bool {
    guard case .Bool(let value) = root else {
      throw DecodingError.typeMismatch(
        Bool.self,
        .init(codingPath: codingPath, debugDescription: "Expected bool", )
      )
    }
    return value.rawValue
  }

  func decode(_ type: String.Type) throws -> String {
    guard case .String(let value) = root else {
      throw DecodingError.typeMismatch(
        String.self,
        .init(codingPath: codingPath, debugDescription: "Expected string", )
      )
    }
    return value.rawValue
  }

  func decode(_ type: Double.Type) throws -> Double {
    guard case .Double(let value) = root else {
      throw DecodingError.typeMismatch(
        Double.self,
        .init(codingPath: codingPath, debugDescription: "Expected double", )
      )
    }
    return value.rawValue
  }

  func decode(_ type: Float.Type) throws -> Float { return Float(try decode(Double.self)) }

  func decode(_ type: Int.Type) throws -> Int { Int(try decode(Int64.self)) }
  func decode(_ type: Int8.Type) throws -> Int8 { Int8(try decode(Int64.self)) }
  func decode(_ type: Int16.Type) throws -> Int16 { Int16(try decode(Int64.self)) }
  func decode(_ type: Int32.Type) throws -> Int32 { Int32(try decode(Int64.self)) }
  func decode(_ type: Int64.Type) throws -> Int64 {
    guard case .Int64(let value) = root else {
      throw DecodingError.typeMismatch(
        Int64.self,
        .init(codingPath: codingPath, debugDescription: "Expected int64", )
      )
    }
    return value.rawValue
  }

  func decode(_ type: UInt.Type) throws -> UInt { UInt(try decode(UInt64.self)) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { UInt8(try decode(UInt16.self)) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { UInt16(try decode(UInt64.self)) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { UInt32(try decode(UInt64.self)) }
  func decode(_ type: UInt64.Type) throws -> UInt64 {
    guard case .UInt64(let value) = root else {
      throw DecodingError.typeMismatch(
        UInt64.self,
        .init(codingPath: codingPath, debugDescription: "Expected uint64", )
      )
    }
    return value.rawValue
  }

  func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
    if let ct = type as? any XPCObject.Type {
      let obj = ct.init(xpc_object: root.xpc_object)
      return obj as! T
    }
    if let ct = type as? any XPCMarshal.Type {
      return try ct.unmarshal(from: root) as! T
    }
    let sub = _XPCDecoder(root: root)
    sub.codingPath = codingPath
    return try T(from: sub)
  }

  func decode<Wrapped>(_ type: XPC<Wrapped>.Type) throws -> XPC<Wrapped> {
    let value = try Wrapped.unmarshal(from: root)
    return XPC<Wrapped>(wrappedValue: value)
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(_ string: String) {
    self.stringValue = string
    self.intValue = nil
  }
  init?(stringValue: String) { self.init(stringValue) }

  init(intValue: Int) {
    self.intValue = intValue
    self.stringValue = String(intValue)
  }
}
