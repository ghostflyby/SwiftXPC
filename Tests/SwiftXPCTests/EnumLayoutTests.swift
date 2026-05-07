// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Testing
import XPC

@testable import SwiftXPC

@Test func EnumLayoutNoPayload() async throws {
  let encoded = try JobState.idle.marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  #expect(type == XPC_TYPE_ARRAY)
  #expect(xpc_array_get_count(object) == 1)

  let casePtr = xpc_array_get_value(object, 0)
  let caseName = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: casePtr))
  #expect(caseName == "idle")
}

@Test func EnumLayoutWithPayload() async throws {
  let encoded = try JobState.compound(title: "retry", retries: 3).marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  #expect(type == XPC_TYPE_ARRAY)
  #expect(xpc_array_get_count(object) == 2)

  let casePtr = xpc_array_get_value(object, 0)
  let caseName = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: casePtr))
  #expect(caseName == "compound")

  let payloadPtr = xpc_array_get_value(object, 1)
  let payloadType = xpc_get_type(payloadPtr)
  #expect(payloadType == XPC_TYPE_ARRAY)
  #expect(xpc_array_get_count(payloadPtr) == 2)

  let titlePtr = xpc_array_get_value(payloadPtr, 0)
  let title = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: titlePtr))
  #expect(title == "retry")

  let retriesPtr = xpc_array_get_value(payloadPtr, 1)
  let retries = try Int.unmarshal(from: SwiftXPC.XPCObject(xpc_object: retriesPtr))
  #expect(retries == 3)
}

@Test func EnumLayoutUnlabeledPayload() async throws {
  let encoded = try JobState.tuple("pair", 2).marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  #expect(type == XPC_TYPE_ARRAY)
  #expect(xpc_array_get_count(object) == 3)

  let casePtr = xpc_array_get_value(object, 0)
  let caseName = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: casePtr))
  #expect(caseName == "tuple")

  let firstPtr = xpc_array_get_value(object, 1)
  let first = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: firstPtr))
  #expect(first == "pair")

  let secondPtr = xpc_array_get_value(object, 2)
  let second = try Int.unmarshal(from: SwiftXPC.XPCObject(xpc_object: secondPtr))
  #expect(second == 2)
}

@Test func RawEnumLayout() async throws {
  let encoded = try RawMode.on.marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  #expect(type == XPC_TYPE_STRING)

  let value = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: object))
  #expect(value == "on")
}
