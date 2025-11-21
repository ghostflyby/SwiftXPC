// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

public enum XPCValue: Sendable, Hashable, Equatable {
  case Bool(XPCBool)
  case Data(XPCData)
  case Double(XPCDouble)
  case Int64(XPCInt64)
  case UInt64(XPCUInt64)
  case String(XPCString)
  case FileDescriptor(XPCFileHandle)
  case Date(XPCDate)
  case UUID(XPCUUID)
  case SharedMemory(XPCSharedMemory)
  case Null(XPCNull)
  case Activity(XPCActivity)
  case Connection(XPCConnection)
  case Endpoint(XPCEndpoint)
  case Dictionary(XPCDictionary)
  case Array(XPCArray)
  case RichError(XPCRichError)
}

extension XPCValue: ExpressibleByNilLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral
{
  public init(nilLiteral: ()) {
    self = .Null(XPCNull())
  }
  public init(floatLiteral value: Double) {
    self = .Double(XPCDouble(floatLiteral: value))
  }
  public init(booleanLiteral value: Bool) {
    self = .Bool(XPCBool(booleanLiteral: value))
  }
  public init(stringLiteral value: String) {
    self = .String(XPCString(stringLiteral: value))
  }
  public init(integerLiteral value: Int64) {
    self = .Int64(XPCInt64(integerLiteral: value))
  }
}

extension XPCValue: XPCObject {
  init(_ xpc_object: xpc_object_t) {
    self.init(xpc_object: xpc_object)
  }
  public init(xpc_object: xpc_object_t) {
    let type = xpc_get_type(xpc_object)
    if #available(macOS 14, *), type == XPC_TYPE_RICH_ERROR {
      self = .RichError(XPCRichError(xpc_object: xpc_object))
      return
    }
    switch type {
    case XPC_TYPE_BOOL:
      self = .Bool(XPCBool(xpc_object: xpc_object))
    case XPC_TYPE_DATA:
      self = .Data(XPCData(xpc_object: xpc_object))
    case XPC_TYPE_DOUBLE:
      self = .Double(XPCDouble(xpc_object: xpc_object))
    case XPC_TYPE_INT64:
      self = .Int64(XPCInt64(xpc_object: xpc_object))
    case XPC_TYPE_UINT64:
      self = .UInt64(XPCUInt64(xpc_object: xpc_object))
    case XPC_TYPE_STRING:
      self = .String(XPCString(xpc_object: xpc_object))
    case XPC_TYPE_FD:
      self = .FileDescriptor(XPCFileHandle(xpc_object: xpc_object))
    case XPC_TYPE_DATE:
      self = .Date(XPCDate(xpc_object: xpc_object))
    case XPC_TYPE_UUID:
      self = .UUID(XPCUUID(xpc_object: xpc_object))
    case XPC_TYPE_SHMEM:
      self = .SharedMemory(XPCSharedMemory(xpc_object: xpc_object))
    case XPC_TYPE_NULL:
      self = .Null(XPCNull())
    case XPC_TYPE_DICTIONARY:
      self = .Dictionary(XPCDictionary(xpc_object: xpc_object))
    case XPC_TYPE_ARRAY:
      self = .Array(XPCArray(xpc_object: xpc_object))
    case XPC_TYPE_ACTIVITY:
      self = .Activity(XPCActivity(xpc_object: xpc_object))
    case XPC_TYPE_CONNECTION:
      self = .Connection(XPCConnection(xpc_object: xpc_object))
    case XPC_TYPE_ENDPOINT:
      self = .Endpoint(XPCEndpoint(xpc_object: xpc_object))
    default:
      fatalError("unknown XPC object type \(type)")
    }
  }
}

extension XPCValue {
  public var xpc_object: xpc_object_t {
    switch self {
    case .Bool(let xpcObject):
      return xpcObject.xpc_object
    case .Data(let xpcObject):
      return xpcObject.xpc_object
    case .Double(let xpcObject):
      return xpcObject.xpc_object
    case .Int64(let xpcObject):
      return xpcObject.xpc_object
    case .UInt64(let xpcObject):
      return xpcObject.xpc_object
    case .String(let xpcObject):
      return xpcObject.xpc_object
    case .FileDescriptor(let xpcObject):
      return xpcObject.xpc_object
    case .Date(let xpcObject):
      return xpcObject.xpc_object
    case .UUID(let xpcObject):
      return xpcObject.xpc_object
    case .SharedMemory(let xpcObject):
      return xpcObject.xpc_object
    case .Null(let xpcObject):
      return xpcObject.xpc_object
    case .Activity(let xpcObject):
      return xpcObject.xpc_object
    case .Connection(let xpcObject):
      return xpcObject.xpc_object
    case .Endpoint(let xpcObject):
      return xpcObject.xpc_object
    case .Dictionary(let xpcObject):
      return xpcObject.xpc_object
    case .Array(let xpcObject):
      return xpcObject.xpc_object
    case .RichError(let xpcObject):
      return xpcObject.xpc_object
    }
  }

}
