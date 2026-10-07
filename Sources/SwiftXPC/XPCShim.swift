// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

/// Compiler support for code emitted into client modules by `@XPCMarshal`.
/// These must be public, but live in one namespace rather than introducing
/// a parallel collection of top-level aliases for native XPC functions.
public enum XPCMarshalRuntime {
  public static func isNull(_ object: xpc_object_t) -> Bool {
    xpc_get_type(object) == XPC_TYPE_NULL
  }

  public static func requireDictionary(_ object: xpc_object_t) throws(XPCMarshalError) {
    try ensureType(object, is: XPC_TYPE_DICTIONARY)
  }

  public static func requireArray(_ object: xpc_object_t) throws(XPCMarshalError) {
    try ensureType(object, is: XPC_TYPE_ARRAY)
  }

  public static func null() -> xpc_object_t { xpc_null_create() }

  public static func string(_ value: String) -> xpc_object_t {
    value.withCString { xpc_string_create($0) }
  }
}

/// A textual description of an XPC object, with native allocation cleanup.
public func xpcCopyDescription(_ object: xpc_object_t) -> String {
  let cString = xpc_copy_description(object)
  defer { free(cString) }
  return String(cString: cString)
}
