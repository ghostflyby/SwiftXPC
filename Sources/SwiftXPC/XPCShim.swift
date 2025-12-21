// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

nonisolated(unsafe) public let xpcTypeNull = XPC.XPC_TYPE_NULL
nonisolated(unsafe) public let xpcTypeDictionary = XPC.XPC_TYPE_DICTIONARY
nonisolated(unsafe) public let xpcTypeArray = XPC.XPC_TYPE_ARRAY

public func xpcGetType(_ object: xpc_object_t) -> xpc_type_t? {
  XPC.xpc_get_type(object)
}

public func xpcDictionaryGetValue(_ dict: xpc_object_t, _ key: String) -> xpc_object_t? {
  key.withCString { XPC.xpc_dictionary_get_value(dict, $0) }
}

public func xpcDictionarySetValue(_ dict: xpc_object_t, _ key: String, _ value: xpc_object_t) {
  key.withCString { XPC.xpc_dictionary_set_value(dict, $0, value) }
}

public func xpcDictionaryCreate(
  _ keys: UnsafePointer<UnsafePointer<CChar>>?, _ values: UnsafePointer<xpc_object_t?>?,
  _ count: Int
) -> xpc_object_t {
  XPC.xpc_dictionary_create(keys, values, count)
}

public func xpcNullCreate() -> xpc_object_t {
  XPC.xpc_null_create()
}

public func xpcArrayCreate(_ values: UnsafePointer<xpc_object_t>?, _ count: Int) -> xpc_object_t {
  XPC.xpc_array_create(values, count)
}

public func xpcArrayAppendValue(_ array: xpc_object_t, _ value: xpc_object_t) {
  XPC.xpc_array_append_value(array, value)
}

public func xpcArrayGetCount(_ array: xpc_object_t) -> Int {
  XPC.xpc_array_get_count(array)
}

public func xpcArrayGetValue(_ array: xpc_object_t, _ index: Int) -> xpc_object_t {
  XPC.xpc_array_get_value(array, index)
}

public func xpcStringCreate(_ string: String) -> xpc_object_t {
  XPC.xpc_string_create(string)
}
