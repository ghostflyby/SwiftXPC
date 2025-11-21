// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import XPC

@frozen
public enum XPCBool: XPCObject, @unchecked Sendable, RawRepresentable,
  ExpressibleByBooleanLiteral, Equatable
{
  public var xpc_object: xpc_object_t {
    switch self {
    case .XPCTrue:
      return XPC_BOOL_TRUE
    case .XPCFalse:
      return XPC_BOOL_FALSE
    }
  }

  public init(xpc_object: xpc_object_t) {
    self.init(xpc_bool_get_value(xpc_object))
  }

  case XPCTrue
  case XPCFalse

}

extension XPCBool {

  public init(_ value: Bool) {
    self = value ? .XPCTrue : .XPCFalse
  }
  public init(rawValue: Bool) {
    self = XPCBool(rawValue)
  }

  public init(booleanLiteral value: Bool) {
    self.init(value)
  }

  public var rawValue: Bool {
    xpc_bool_get_value(xpc_object)
  }

}

@frozen
public struct XPCData: XPCObject, @unchecked Sendable, RawRepresentable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }
}

extension XPCData {
  public init(_ data: Data) {
    self.xpc_object = xpc_data_create(data.withUnsafeBytes { $0.baseAddress }, data.count)
  }

  public init(_ buffer: UnsafeRawBufferPointer) {
    self.xpc_object = xpc_data_create(buffer.baseAddress, buffer.count)
  }

  public init(_ buffer: UnsafeBufferPointer<UInt8>) {
    self.xpc_object = xpc_data_create(buffer.baseAddress, buffer.count)
  }

  public init(_ span: RawSpan) {
    self.xpc_object = xpc_data_create(
      span.withUnsafeBytes({ buffer in buffer.baseAddress }), span.byteCount)
  }

  public init(_ span: Span<UInt8>) {
    self.xpc_object = xpc_data_create(
      span.withUnsafeBytes({ buffer in buffer.baseAddress }),
      span.count * MemoryLayout<UInt8>.size)
  }

  public init(bytes: UnsafeRawPointer, length: Int) {
    self.xpc_object = xpc_data_create(bytes, length)
  }

  public init(rawValue: Data) {
    self = XPCData(rawValue)
  }

  public var rawValue: Data {
    let length = xpc_data_get_length(xpc_object)
    let pointer = xpc_data_get_bytes_ptr(xpc_object)!
    return Data(bytes: pointer, count: length)
  }

}

@frozen
public struct XPCDouble: XPCObject, @unchecked Sendable, RawRepresentable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

}

extension XPCDouble: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) {
    self.init(value)
  }
  public init(_ value: Double) {
    self.xpc_object = xpc_double_create(value)
  }

  public init(rawValue: Double) {
    self = XPCDouble(rawValue)
  }

  public var rawValue: Double {
    xpc_double_get_value(xpc_object)
  }

}

@frozen
public struct XPCInt64: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }
}

extension XPCInt64: RawRepresentable, ExpressibleByIntegerLiteral {
  public init(_ value: Int64) {
    self.xpc_object = xpc_int64_create(value)
  }

  public init(rawValue: Int64) {
    self = XPCInt64(rawValue)
  }

  public var rawValue: Int64 {
    xpc_int64_get_value(xpc_object)
  }

  public init(integerLiteral value: Int64) {
    self.init(value)
  }

}

@frozen
public struct XPCUInt64: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

}

extension XPCUInt64: RawRepresentable, ExpressibleByIntegerLiteral {
  public init(_ value: UInt64) {
    self.xpc_object = xpc_uint64_create(value)
  }

  public init(rawValue: UInt64) {
    self = XPCUInt64(rawValue)
  }

  public var rawValue: UInt64 {
    xpc_uint64_get_value(xpc_object)
  }

  public init(integerLiteral value: UInt64) {
    self.init(value)
  }

}

@frozen
public struct XPCString: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }
}

extension XPCString: RawRepresentable, ExpressibleByStringLiteral {
  public init(_ value: String) {
    self.xpc_object = xpc_string_create(value)
  }

  public init(rawValue: String) {
    self = XPCString(rawValue)
  }

  public var rawValue: String {
    let cString = xpc_string_get_string_ptr(xpc_object)!
    return String(cString: cString)
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public init(_ cString: UnsafePointer<CChar>) {
    self.xpc_object = xpc_string_create(cString)
  }

}

@frozen
public struct XPCFileHandle: XPCObject, @unchecked Sendable {

  public var wrappedValue: FileHandle {
    asFileHandle()
  }
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

  private enum CodingKeys: CodingKey {
    case xpc_object
  }
}

extension XPCFileHandle {
  public init(_ fileHandle: FileHandle) {
    self.xpc_object = xpc_fd_create(fileHandle.fileDescriptor)!
  }

  public init(fd: Int32) {
    self.xpc_object = xpc_fd_create(fd)!
  }

  public func asFileHandle<T>(type: T.Type = T.self) -> T where T: FileHandle {
    return T(fileDescriptor: xpc_fd_dup(xpc_object), closeOnDealloc: true)
  }

  public var fileDescriptor: Int32 {
    return xpc_fd_dup(xpc_object)
  }

}

@frozen
public struct XPCDate: XPCObject, @unchecked Sendable, RawRepresentable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

}

extension XPCDate {
  public init(_ date: Date) {
    self.xpc_object = xpc_date_create(Int64(date.timeIntervalSince1970))
  }

  public init(rawValue: Date) {
    self = XPCDate(rawValue)
  }

  public var rawValue: Date {
    let timeInterval = xpc_date_get_value(xpc_object)
    return Date(timeIntervalSince1970: Double(timeInterval))
  }

}

@frozen
public struct XPCUUID: XPCObject, @unchecked Sendable, RawRepresentable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

}

extension XPCUUID {
  public init(_ uuid: UUID) {
    var uuid = uuid.uuid
    self.xpc_object = xpc_uuid_create(&uuid)
  }

  public init(rawValue: UUID) {
    self = XPCUUID(rawValue)
  }

  public var rawValue: UUID {
    let uuid = xpc_uuid_get_bytes(xpc_object)
    return
      (uuid?.withMemoryRebound(to: uuid_t.self, capacity: 1) { ptr in
        return UUID(uuid: ptr.pointee)
      })!
  }

}

@frozen
public struct XPCSharedMemory: XPCObject, @unchecked Sendable, RawRepresentable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }
}

extension XPCSharedMemory {
  public init(_ buffer: UnsafeMutableRawBufferPointer) {
    self.xpc_object = xpc_shmem_create(buffer.baseAddress!, buffer.count)
  }

  public init(rawValue: UnsafeMutableRawBufferPointer) {
    self = XPCSharedMemory(rawValue)
  }

  public var rawValue: UnsafeMutableRawBufferPointer {
    var pointer: UnsafeMutableRawPointer? = nil
    let length = xpc_shmem_map(xpc_object, &pointer)
    return UnsafeMutableRawBufferPointer(start: pointer, count: length)
  }

}

@frozen
public struct XPCNull: XPCObject, @unchecked Sendable {

  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

}

extension XPCNull: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) {
    self.init()
  }

  public static let shared = Self.init(xpc_object: xpc_null_create())
  public init() {
    self = XPCNull.shared
  }

}

@frozen
public struct XPCArray: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }

}

extension XPCArray: RandomAccessCollection {

  public var startIndex: Int {
    0
  }

  public var endIndex: Int {
    Int(xpc_array_get_count(xpc_object))
  }

}

extension XPCArray: MutableCollection {
  public typealias Element = any XPCObject

  private func validateIndex(_ position: Int) {
    precondition(position >= startIndex && position < endIndex, "Index out of bounds")
  }

  public subscript(position: Int) -> any XPCObject {
    get {
      validateIndex(position)
      let item = xpc_array_get_value(xpc_object, position)
      return XPCObjectUnknown(xpc_object: item)
    }
    set {
      validateIndex(position)
      xpc_array_set_value(xpc_object, position, newValue.xpc_object)
    }
  }

  public subscript(position: Int) -> XPCValue {
    get {
      validateIndex(position)
      let item = xpc_array_get_value(xpc_object, position)
      return XPCValue(item)
    }
  }

}

extension XPCArray {
  mutating func append(_ obj: any XPCObject) {
    xpc_array_append_value(xpc_object, obj.xpc_object)
  }
}

extension XPCArray {
  public init() {
    self.init(xpc_object: xpc_array_create_empty())
  }
}

@frozen
public struct XPCDictionary: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
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

  public subscript(key: String) -> (any XPCObject)? {
    get {
      if let item = xpc_dictionary_get_value(xpc_object, key) {
        XPCObjectUnknown(xpc_object: item)
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

  public subscript(key: String) -> XPCValue? {
    get {
      if let item = xpc_dictionary_get_value(xpc_object, key) {
        XPCValue(item)
      } else {
        nil
      }
    }
  }
}

@frozen
public struct XPCActivity: XPCObject, @unchecked Sendable {
  public let xpc_object: xpc_object_t
  public init(xpc_object: xpc_object_t) {
    self.xpc_object = xpc_object
  }
}
