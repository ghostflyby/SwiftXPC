// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Testing
import XPC

@testable import SwiftXPC

@Test func StructXPCLayout() async throws {
  let value = Greeting(id: 1, message: "hello", note: nil)
  let encoded = try value.marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  assert(type == XPC_TYPE_DICTIONARY)

  guard let idPtr = xpc_dictionary_get_value(object, "id") else {
    throw SwiftXPC.XPCMarshalError.missingKey("id")
  }
  let id = try Int.unmarshal(from: SwiftXPC.XPCObject(xpc_object: idPtr))
  assert(id == 1)

  guard let messagePtr = xpc_dictionary_get_value(object, "message") else {
    throw SwiftXPC.XPCMarshalError.missingKey("message")
  }
  let message = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: messagePtr))
  assert(message == "hello")

  guard let notePtr = xpc_dictionary_get_value(object, "note") else {
    throw SwiftXPC.XPCMarshalError.missingKey("note")
  }
  assert(xpc_get_type(notePtr) == XPC_TYPE_NULL)
}
