// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
  import XPC

  // Implementation support for macro-generated code, which expands in user
  // modules and therefore needs public symbols. Do not build on these
  // directly; prefer the XPCObject/XPCArray/XPCDictionary wrappers.

  nonisolated(unsafe) public let xpcTypeNull = XPC.XPC_TYPE_NULL
  nonisolated(unsafe) public let xpcTypeDictionary = XPC.XPC_TYPE_DICTIONARY
  nonisolated(unsafe) public let xpcTypeArray = XPC.XPC_TYPE_ARRAY

  public func xpcGetType(_ object: xpc_object_t) -> xpc_type_t {
    XPC.xpc_get_type(object)
  }

  public func xpcTypeGetName(_ type: xpc_type_t) -> UnsafePointer<CChar> {
    XPC.xpc_type_get_name(type)
  }

  public func xpcNullCreate() -> xpc_object_t {
    XPC.xpc_null_create()
  }

  public func xpcStringCreate(_ string: String) -> xpc_object_t {
    XPC.xpc_string_create(string)
  }

#endif
