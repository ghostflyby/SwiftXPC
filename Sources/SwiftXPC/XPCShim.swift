// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

// Implementation support for macro-generated code, which expands in user
// modules and therefore needs public symbols. Do not build on these
// directly; raw handles interoperate with the (re-exported) Apple
// XPCDictionary/XPCArray containers.

nonisolated(unsafe) public let xpcTypeNull = XPC_TYPE_NULL
nonisolated(unsafe) public let xpcTypeDictionary = XPC_TYPE_DICTIONARY
nonisolated(unsafe) public let xpcTypeArray = XPC_TYPE_ARRAY

public func xpcGetType(_ object: xpc_object_t) -> xpc_type_t {
  xpc_get_type(object)
}

public func xpcTypeGetName(_ type: xpc_type_t) -> UnsafePointer<CChar> {
  xpc_type_get_name(type)
}

public func xpcNullCreate() -> xpc_object_t {
  xpc_null_create()
}

public func xpcStringCreate(_ string: String) -> xpc_object_t {
  xpc_string_create(string)
}

/// A textual description of an XPC object, for diagnostics.
public func xpcCopyDescription(_ object: xpc_object_t) -> String {
  let cString = xpc_copy_description(object)
  defer { free(cString) }
  return String(cString: cString)
}
