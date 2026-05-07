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
  #expect(type == XPC_TYPE_DICTIONARY)

  guard let idPtr = xpc_dictionary_get_value(object, "id") else {
    throw SwiftXPC.XPCMarshalError.missingKey("id")
  }
  let id = try Int.unmarshal(from: SwiftXPC.XPCObject(xpc_object: idPtr))
  #expect(id == 1)

  guard let messagePtr = xpc_dictionary_get_value(object, "message") else {
    throw SwiftXPC.XPCMarshalError.missingKey("message")
  }
  let message = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: messagePtr))
  #expect(message == "hello")

  guard let notePtr = xpc_dictionary_get_value(object, "note") else {
    throw SwiftXPC.XPCMarshalError.missingKey("note")
  }
  #expect(xpc_get_type(notePtr) == XPC_TYPE_NULL)
}

@Test func FrozenStructXPCLayout() async throws {
  let value = FrozenGreeting(id: 1, message: "hello", note: nil)
  let encoded = try value.marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  #expect(type == XPC_TYPE_ARRAY)
  #expect(xpc_array_get_count(object) == 3)

  let idPtr = xpc_array_get_value(object, 0)
  let id = try Int.unmarshal(from: SwiftXPC.XPCObject(xpc_object: idPtr))
  #expect(id == 1)

  let messagePtr = xpc_array_get_value(object, 1)
  let message = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: messagePtr))
  #expect(message == "hello")

  let notePtr = xpc_array_get_value(object, 2)
  #expect(xpc_get_type(notePtr) == XPC_TYPE_NULL)
}
